module Runtime.Store
  ( loadSnapshot
  , writeSnapshot
  , appendWal
  , replayWal
  , resetWal
  , rotateSnapshotAndWal
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
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile, removeFile)
import System.FilePath ((</>), takeDirectory)
import Control.Monad (foldM)
import Control.Exception (try, SomeException, bracket)
import System.Posix.IO (openFd, defaultFileFlags, OpenMode(..), closeFd, fsync)
import System.Posix.Process (getProcessID)

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
    Right bytes -> atomicWriteFile path bytes

appendWal :: FilePath -> BS.ByteString -> IO (Either String ())
appendWal dir payload = do
  createDirectoryIfMissing True (dir </> "wal")
  let path = walPath dir
  let entry = BL.toStrict $ runPut $ do
        putWord32le (fromIntegral (BS.length payload))
        putByteString payload
  BS.appendFile path entry
  _ <- fsyncPath path
  pure (Right ())

resetWal :: FilePath -> IO (Either String ())
resetWal dir = do
  createDirectoryIfMissing True (dir </> "wal")
  atomicWriteFile (walPath dir) BS.empty

rotateSnapshotAndWal :: FilePath -> Snapshot -> IO (Either String ())
rotateSnapshotAndWal dir snap = do
  createDirectoryIfMissing True (dir </> "snapshots")
  createDirectoryIfMissing True (dir </> "wal")
  case encodeSnapshot snap of
    Left err -> pure (Left (show err))
    Right bytes -> do
      r1 <- atomicWriteFile (snapshotPath dir) bytes
      case r1 of
        Left err -> pure (Left ("snapshot rotate failed: " ++ err))
        Right () -> do
          r2 <- atomicWriteFile (walPath dir) BS.empty
          case r2 of
            Left err -> pure (Left ("wal reset failed: " ++ err))
            Right () -> pure (Right ())

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
          payload <- getByteString (fromIntegral len)
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
