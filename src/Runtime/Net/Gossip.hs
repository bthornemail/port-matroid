{-# LANGUAGE LambdaCase #-}

module Runtime.Net.Gossip
  ( GossipEnv(..)
  , mkSummary
  , decidePull
  , handlePullReq
  , applyPullSnap
  , applyPullWal
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Word (Word16, Word32, Word64)
import Data.Bits (shiftL)

import Runtime.Net.Gossip.Types
import Runtime.Store
  ( Manifest(..)
  , readManifest
  , currentSnapshotPath
  , currentWalPath
  , writeBlobAtomic
  , writeManifest
  , ensureWalHeader
  , verifyWalHeader
  , walVersion
  , walHeader
  , crc32
  , replayWalWith
  , loadSnapshot
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Snapshot.Decode (decodeSnapshot)

data GossipEnv = GossipEnv
  { geDataDir :: !FilePath
  , geMaxWalChunkBytes :: !Word32
  , geMaxSnapBytes :: !Int
  }

mkSummary :: NodeId -> Word64 -> GossipEnv -> IO (Either String Summary)
mkSummary nid epoch env = do
  m <- readManifest (geDataDir env)
  snapPath <- currentSnapshotPath (geDataDir env)
  walPath <- currentWalPath (geDataDir env)
  snapBytes <- BS.readFile snapPath
  walBytes <- BS.readFile walPath
  let snapHash = if BS.length snapBytes >= 32 then BS.drop (BS.length snapBytes - 32) snapBytes else BS.empty
      gen = case m of
        Right mf -> fromIntegral (mfGen mf)
        Left _ -> 0
      walLen = fromIntegral (BS.length walBytes)
  pure $ Right Summary
    { sNodeId = nid
    , sEpoch = epoch
    , sGen = gen
    , sSnapHash = snapHash
    , sWalBytes = walLen
    , sWalVersion = walVersion
    }

decidePull :: Summary -> Summary -> Maybe Msg
decidePull me other
  | sSnapHash me == sSnapHash other =
      if sWalBytes other > sWalBytes me
        then Just MPullReq
          { prWantGen = sGen other
          , prWantHash = sSnapHash me
          , prFromOff = sWalBytes me
          , prMaxBytes = 0
          }
        else Nothing
  | sEpoch other > sEpoch me = Just MPullReq
      { prWantGen = sGen other
      , prWantHash = sSnapHash other
      , prFromOff = 0
      , prMaxBytes = 0
      }
  | sEpoch other == sEpoch me && sGen other > sGen me = Just MPullReq
      { prWantGen = sGen other
      , prWantHash = sSnapHash other
      , prFromOff = 0
      , prMaxBytes = 0
      }
  | otherwise = Nothing

handlePullReq :: GossipEnv -> Summary -> Msg -> IO (Either Nack Msg)
handlePullReq env me = \case
  MPullReq wantGen wantHash fromOff maxBytes -> do
    let maxChunk = if maxBytes == 0 then geMaxWalChunkBytes env else min maxBytes (geMaxWalChunkBytes env)
    if wantHash /= sSnapHash me
      then do
        snapPath <- currentSnapshotPath (geDataDir env)
        snapBytes <- BS.readFile snapPath
        if BS.length snapBytes > geMaxSnapBytes env
          then pure (Left (Nack TooLarge (BSC.pack "snapshot too large")))
          else pure (Right (MPullSnap (sGen me) (sSnapHash me) snapBytes))
      else do
        walPath <- currentWalPath (geDataDir env)
        h <- verifyWalHeader walPath
        case h of
          Left _ -> pure (Left (Nack BadMsg (BSC.pack "wal header invalid")))
          Right () -> do
            walBytes <- BS.readFile walPath
            case walChunkFromOffset walBytes fromOff maxChunk of
              Left err -> pure (Left (Nack BadOffset (BS.pack (map (fromIntegral . fromEnum) err))))
              Right chunk ->
                pure (Right (MPullWal (sGen me) (sSnapHash me) fromOff chunk))
  _ -> pure (Left (Nack BadMsg (BSC.pack "unexpected")))

applyPullSnap :: GossipEnv -> Msg -> IO (Either Nack ())
applyPullSnap env = \case
  MPullSnap gen snapHash bytes -> do
    if BS.length bytes > geMaxSnapBytes env
      then pure (Left (Nack TooLarge (BSC.pack "snapshot too large")))
      else case decodeSnapshot bytes of
        Left _ -> pure (Left (Nack BadMsg (BSC.pack "snapshot decode failed")))
        Right _ -> do
          let actualHash = if BS.length bytes >= 32 then BS.drop (BS.length bytes - 32) bytes else BS.empty
          if actualHash /= snapHash
            then pure (Left (Nack HashMismatch (BSC.pack "snapshot hash mismatch")))
            else do
              let snapDir = geDataDir env </> "snapshots"
              let walDir = geDataDir env </> "wal"
              createDirectoryIfMissing True snapDir
              createDirectoryIfMissing True walDir
              let snapFile = snapDir </> ("snap." ++ show gen ++ ".csnp")
              let walFile = walDir </> ("wal." ++ show gen ++ ".wal")
              _ <- writeBlobAtomic snapFile bytes
              _ <- ensureWalHeader walFile
              _ <- writeManifest (geDataDir env) (Manifest (fromIntegral gen) snapFile walFile)
              pure (Right ())
  _ -> pure (Left (Nack BadMsg (BSC.pack "unexpected")))

applyPullWal :: GossipEnv -> Msg -> IO (Either Nack ())
applyPullWal env = \case
  MPullWal _gen snapHash offset bytes -> do
    snapPath <- currentSnapshotPath (geDataDir env)
    snapBytes <- BS.readFile snapPath
    let actualHash = if BS.length snapBytes >= 32 then BS.drop (BS.length snapBytes - 32) snapBytes else BS.empty
    if snapHash /= actualHash
      then pure (Left (Nack HashMismatch (BSC.pack "base snapshot hash mismatch")))
      else do
        walPath <- currentWalPath (geDataDir env)
        h <- verifyWalHeader walPath
        case h of
          Left _ -> pure (Left (Nack BadMsg (BSC.pack "wal header invalid")))
          Right () -> do
            walBytes <- BS.readFile walPath
            let currentSize = fromIntegral (BS.length walBytes)
            if offset /= currentSize
              then pure (Left (Nack BadOffset (BSC.pack "offset not at end")))
              else do
                -- validate chunk entries strictly before appending
                case parseWalChunk bytes of
                  Left err -> pure (Left (Nack BadMsg (BS.pack (map (fromIntegral . fromEnum) err))))
                  Right () -> do
                    BS.appendFile walPath bytes
                    -- replay to ensure correctness; fail closed on error
                    snapRes <- loadSnapshot (geDataDir env)
                    case snapRes of
                      Left _ -> pure (Left (Nack BadMsg (BSC.pack "snapshot load failed")))
                      Right snap -> do
                        r <- replayWalWith False (geDataDir env) snap
                        case r of
                          Left _ -> pure (Left (Nack BadMsg (BSC.pack "wal replay failed")))
                          Right _ -> pure (Right ())
  _ -> pure (Left (Nack BadMsg (BSC.pack "unexpected")))

-- ----------------------------
-- Helpers
-- ----------------------------

walChunkFromOffset :: ByteString -> Word64 -> Word32 -> Either String ByteString
walChunkFromOffset bytes offset maxBytes =
  let hdrLen = fromIntegral (BS.length walHeader)
      total = fromIntegral (BS.length bytes)
  in if total < hdrLen
       then Left "wal header missing"
       else if offset < hdrLen || offset > total
         then Left "offset out of range"
         else
           case findBoundary bytes (fromIntegral offset) of
             False -> Left "offset not entry boundary"
             True ->
               let maxEnd = min total (fromIntegral offset + fromIntegral maxBytes)
                   chunk = BS.take (fromIntegral (maxEnd - fromIntegral offset)) (BS.drop (fromIntegral offset) bytes)
                   trimmed = trimToEntryBoundary chunk
               in Right trimmed
  where
    findBoundary bs off = off == fromIntegral (BS.length walHeader) || any (\(o, _) -> o == off) (entryOffsets bs)

entryOffsets :: ByteString -> [(Int, Int)]
entryOffsets bytes =
  let hdrLen = BS.length walHeader
      total = BS.length bytes
      go off acc =
        if off == total
          then reverse acc
          else if off + 8 > total
            then reverse acc
            else
              let len = get32 off
                  start = off + 8
                  end = start + fromIntegral len
              in if end > total
                   then reverse acc
                   else go end ((off, end):acc)
  in go hdrLen []
  where
    get32 i =
      let b0 = fromIntegral (BS.index bytes i) :: Word32
          b1 = fromIntegral (BS.index bytes (i + 1)) :: Word32
          b2 = fromIntegral (BS.index bytes (i + 2)) :: Word32
          b3 = fromIntegral (BS.index bytes (i + 3)) :: Word32
      in b0 + (b1 `shiftL` 8) + (b2 `shiftL` 16) + (b3 `shiftL` 24)

trimToEntryBoundary :: ByteString -> ByteString
trimToEntryBoundary chunk =
  case parseWalChunkPrefix chunk of
    Left _ -> BS.empty
    Right n -> BS.take n chunk

parseWalChunkPrefix :: ByteString -> Either String Int
parseWalChunkPrefix bs =
  let total = BS.length bs
      go off =
        if off == total
          then Right total
          else if off + 8 > total
            then Right off
            else
              let len = get32 off
                  start = off + 8
                  end = start + fromIntegral len
              in if end > total
                   then Right off
                   else go end
  in go 0
  where
    get32 i =
      let b0 = fromIntegral (BS.index bs i) :: Word32
          b1 = fromIntegral (BS.index bs (i + 1)) :: Word32
          b2 = fromIntegral (BS.index bs (i + 2)) :: Word32
          b3 = fromIntegral (BS.index bs (i + 3)) :: Word32
      in b0 + (b1 `shiftL` 8) + (b2 `shiftL` 16) + (b3 `shiftL` 24)

parseWalChunk :: ByteString -> Either String ()
parseWalChunk bs =
  let total = BS.length bs
      go off =
        if off == total
          then Right ()
          else if off + 8 > total
            then Left "wal chunk trailing partial entry"
            else
              let len = get32 off
                  crc = get32 (off + 4)
                  start = off + 8
                  end = start + fromIntegral len
              in if end > total
                   then Left "wal chunk trailing partial entry"
                   else
                     let payload = BS.take (fromIntegral len) (BS.drop start bs)
                     in if crc /= crc32 payload
                          then Left "wal chunk checksum mismatch"
                          else go end
  in go 0
  where
    get32 i =
      let b0 = fromIntegral (BS.index bs i) :: Word32
          b1 = fromIntegral (BS.index bs (i + 1)) :: Word32
          b2 = fromIntegral (BS.index bs (i + 2)) :: Word32
          b3 = fromIntegral (BS.index bs (i + 3)) :: Word32
      in b0 + (b1 `shiftL` 8) + (b2 `shiftL` 16) + (b3 `shiftL` 24)
