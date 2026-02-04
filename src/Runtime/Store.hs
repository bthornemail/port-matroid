module Runtime.Store
  ( loadSnapshot
  , writeSnapshot
  , appendWal
  , replayWal
  , walPath
  , snapshotPath
  ) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Types (Snapshot)
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..))

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Binary.Get
import Data.Binary.Put
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

snapshotPath :: FilePath -> FilePath
snapshotPath dir = dir </> "snapshots" </> "latest.csnp"

walPath :: FilePath -> FilePath
walPath dir = dir </> "wal" </> "current.wal"

loadSnapshot :: FilePath -> IO (Either String Snapshot)
loadSnapshot dir = do
  let path = snapshotPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Left "snapshot missing")
    else do
      bytes <- BS.readFile path
      pure (either (Left . show) Right (decodeSnapshot bytes))

writeSnapshot :: FilePath -> Snapshot -> IO (Either String ())
writeSnapshot dir snap = do
  let path = snapshotPath dir
  createDirectoryIfMissing True (dir </> "snapshots")
  case encodeSnapshot snap of
    Left err -> pure (Left (show err))
    Right bytes -> BS.writeFile path bytes >> pure (Right ())

appendWal :: FilePath -> BS.ByteString -> IO (Either String ())
appendWal dir payload = do
  createDirectoryIfMissing True (dir </> "wal")
  let path = walPath dir
  let entry = BL.toStrict $ runPut $ do
        putWord32le (fromIntegral (BS.length payload))
        putByteString payload
  BS.appendFile path entry
  pure (Right ())

replayWal :: FilePath -> Snapshot -> IO (Either String Snapshot)
replayWal dir snap = do
  let path = walPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Right snap)
    else do
      bytes <- BS.readFile path
      case runGetOrFail getEntries (BL.fromStrict bytes) of
        Left _ -> pure (Left "wal parse error")
        Right (_, _, entries) -> applyAll snap entries
  where
    getEntries = do
      done <- isEmpty
      if done
        then pure []
        else do
          len <- getWord32le
          payload <- getByteString (fromIntegral len)
          rest <- getEntries
          pure (payload : rest)

    applyAll s [] = pure (Right s)
    applyAll s (b:bs) =
      case decodeStream b of
        Left _ -> pure (Left "wal decode failure")
        Right instrs ->
          case applyInstructions s (AuthorityMask 0xF) instrs of
            (Halt r, _) -> pure (Left ("wal replay halted: " ++ show r))
            (Next, s') -> applyAll s' bs
