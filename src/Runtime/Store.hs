module Runtime.Store
  ( loadSnapshot
  , writeSnapshot
  , appendWal
  , replayWal
  , resetWal
  , rotateSnapshotAndWal
  , writeBlobAtomic
  , walPath
  , snapshotPath
  , Manifest(..)
  , manifestPath
  , readManifest
  , writeManifest
  , currentSnapshotPath
  , currentWalPath
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
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile, removeFile)
import System.FilePath ((</>), takeDirectory)
import Control.Monad (foldM)
import Control.Exception (try, SomeException, bracket)
import System.Posix.IO (openFd, defaultFileFlags, OpenMode(..), closeFd, fsync)
import System.Posix.Process (getProcessID)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Bits (xor, (.&.), shiftR)
import qualified Data.List as List

snapshotPath :: FilePath -> FilePath
snapshotPath dir = dir </> "snapshots" </> "latest.csnp"

walPath :: FilePath -> FilePath
walPath dir = dir </> "wal" </> "current.wal"

data Manifest = Manifest
  { mfSnapshot :: FilePath
  , mfWal :: FilePath
  } deriving (Eq, Show)

manifestPath :: FilePath -> FilePath
manifestPath dir = dir </> "manifest"

readManifest :: FilePath -> IO (Either String Manifest)
readManifest dir = do
  let path = manifestPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Left "manifest missing")
    else do
      bytes <- BS.readFile path
      let ls = lines (map (toEnum . fromEnum) (BS.unpack bytes))
      case parseLines ls of
        Left err -> pure (Left err)
        Right m -> pure (Right m)
  where
    parseLines ls =
      case (lookup "snapshot" kvs, lookup "wal" kvs) of
        (Just s, Just w) -> Right (Manifest s w)
        _ -> Left "manifest incomplete"
      where
        kvs = [ let (k, v') = break (== '=') l in (k, drop 1 v') | l <- ls, '=' `elem` l ]

writeManifest :: FilePath -> Manifest -> IO (Either String ())
writeManifest dir mf = do
  let payload = "snapshot=" ++ mfSnapshot mf ++ "\nwal=" ++ mfWal mf ++ "\n"
  atomicWriteFile (manifestPath dir) (BS.pack (map (toEnum . fromEnum) payload))

currentSnapshotPath :: FilePath -> IO FilePath
currentSnapshotPath dir = do
  m <- readManifest dir
  case m of
    Right mf -> pure (mfSnapshot mf)
    Left _ -> pure (snapshotPath dir)

currentWalPath :: FilePath -> IO FilePath
currentWalPath dir = do
  m <- readManifest dir
  case m of
    Right mf -> pure (mfWal mf)
    Left _ -> pure (walPath dir)

loadSnapshot :: FilePath -> IO (Either String Snapshot)
loadSnapshot dir = do
  path <- currentSnapshotPath dir
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
    Right bytes -> atomicWriteFile path bytes

appendWal :: FilePath -> BS.ByteString -> IO (Either String ())
appendWal dir payload = do
  createDirectoryIfMissing True (dir </> "wal")
  path <- currentWalPath dir
  let crc = crc32 payload
  let entry = BL.toStrict $ runPut $ do
        putWord32le (fromIntegral (BS.length payload))
        putWord32le crc
        putByteString payload
  BS.appendFile path entry
  _ <- fsyncPath path
  pure (Right ())

resetWal :: FilePath -> IO (Either String ())
resetWal dir = do
  createDirectoryIfMissing True (dir </> "wal")
  path <- currentWalPath dir
  atomicWriteFile path BS.empty

rotateSnapshotAndWal :: FilePath -> Snapshot -> IO (Either String ())
rotateSnapshotAndWal dir snap = do
  createDirectoryIfMissing True (dir </> "snapshots")
  createDirectoryIfMissing True (dir </> "wal")
  case encodeSnapshot snap of
    Left err -> pure (Left (show err))
    Right bytes -> do
      gen <- newGeneration
      let snapFile = dir </> "snapshots" </> ("snap." ++ gen ++ ".csnp")
      let walFile = dir </> "wal" </> ("wal." ++ gen ++ ".wal")
      r1 <- atomicWriteFile snapFile bytes
      case r1 of
        Left err -> pure (Left ("snapshot rotate failed: " ++ err))
        Right () -> do
          r2 <- atomicWriteFile walFile BS.empty
          case r2 of
            Left err -> pure (Left ("wal reset failed: " ++ err))
            Right () -> do
              let mf = Manifest { mfSnapshot = snapFile, mfWal = walFile }
              r3 <- writeManifest dir mf
              case r3 of
                Left err -> pure (Left ("manifest write failed: " ++ err))
                Right () -> pure (Right ())

replayWal :: FilePath -> Snapshot -> IO (Either String Snapshot)
replayWal dir snap = do
  path <- currentWalPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Right snap)
    else do
      bytes <- BS.readFile path
      case runGetOrFail getEntries (BL.fromStrict bytes) of
        Left _ -> pure (Left "wal parse error")
        Right (_, _, entries) ->
          case foldM applyOne snap entries of
            Left err -> pure (Left err)
            Right res -> pure (Right res)
  where
    getEntries = do
      done <- isEmpty
      if done
        then pure []
        else do
          len <- getWord32le
          crc <- getWord32le
          payload <- getByteString (fromIntegral len)
          if crc /= crc32 payload
            then fail "wal checksum mismatch"
            else pure ()
          rest <- getEntries
          pure (payload : rest)

    applyOne s b =
      case decodeStream b of
        Left _ -> Left "wal decode failure"
        Right instrs ->
          case applyInstructions s (AuthorityMask 0xF) instrs of
            (Halt r, _) -> Left ("wal replay halted: " ++ show r)
            (Next, s') -> Right s'

atomicWriteFile :: FilePath -> BS.ByteString -> IO (Either String ())
atomicWriteFile final bytes = do
  pid <- getProcessID
  let tmp = final ++ ".tmp." ++ show pid
  r <- try $ do
    createDirectoryIfMissing True (takeDirectory final)
    BS.writeFile tmp bytes
    _ <- fsyncPath tmp
    renameFile tmp final
    fsyncDir (takeDirectory final)
  case r of
    Left (e :: SomeException) -> do
      _ <- try (removeFile tmp) :: IO (Either SomeException ())
      pure (Left (show e))
    Right () -> pure (Right ())

fsyncPath :: FilePath -> IO ()
fsyncPath path =
  bracket (openFd path ReadOnly Nothing defaultFileFlags) closeFd fsync

fsyncDir :: FilePath -> IO ()
fsyncDir dir =
  bracket (openFd dir ReadOnly Nothing defaultFileFlags) closeFd fsync

writeBlobAtomic :: FilePath -> BS.ByteString -> IO (Either String ())
writeBlobAtomic = atomicWriteFile

newGeneration :: IO String
newGeneration = do
  pid <- getProcessID
  t <- getPOSIXTime
  pure (show pid ++ "." ++ filter (/= '.') (show t))

crc32 :: BS.ByteString -> Word32
crc32 bs = BS.foldl' step 0xFFFFFFFF bs `xor` 0xFFFFFFFF
  where
    step crc b =
      let idx = fromIntegral ((crc `xor` fromIntegral b) .&. 0xFF)
      in (crc `shiftR` 8) `xor` table !! idx

    table = map mk [0..255]
    mk i = List.foldl' (\c _ -> if c .&. 1 == 1 then 0xEDB88320 `xor` (c `shiftR` 1) else c `shiftR` 1) (fromIntegral i) [1..8]
