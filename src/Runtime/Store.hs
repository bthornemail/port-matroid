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
  , manifestGeneration
  , walEntryCount
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
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile, removeFile, listDirectory, getFileSize)
import System.FilePath ((</>), takeDirectory)
import Control.Monad (foldM)
import Control.Exception (try, SomeException, bracket)
import System.IO.Error (catchIOError)
import Data.Char (isSpace)
import System.Posix.IO (openFd, defaultFileFlags, OpenMode(..), closeFd, fsync)
import System.Posix.Process (getProcessID)
import Data.Bits (xor, (.&.), shiftR)
import qualified Data.List as List
import Text.Read (readMaybe)

snapshotPath :: FilePath -> FilePath
snapshotPath dir = dir </> "snapshots" </> "latest.csnp"

walPath :: FilePath -> FilePath
walPath dir = dir </> "wal" </> "current.wal"

data Manifest = Manifest
  { mfGen :: Int
  , mfSnapshot :: FilePath
  , mfWal :: FilePath
  } deriving (Eq, Show)

manifestGeneration :: Manifest -> Int
manifestGeneration = mfGen

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
      let ls = map stripLine (lines (map (toEnum . fromEnum) (BS.unpack bytes)))
      case parseLines ls of
        Left err -> pure (Left err)
        Right m -> pure (Right m)
  where
    parseLines ls =
      case (lookup "gen" kvs, lookup "snapshot" kvs, lookup "wal" kvs) of
        (Just g, Just s, Just w) ->
          case readMaybe g of
            Just n -> Right (Manifest n s w)
            Nothing -> Left "manifest bad gen"
        _ -> Left "manifest incomplete"
      where
        kvs =
          [ let (k, v') = break (== '=') l in (k, drop 1 v')
          | l <- ls
          , not (null l)
          , head l /= '#'
          , '=' `elem` l
          ]
    stripLine = trim . dropWhile isSpace
    trim = reverse . dropWhile isSpace . reverse . dropWhile (== '\r')

writeManifest :: FilePath -> Manifest -> IO (Either String ())
writeManifest dir mf = do
  let payload = "gen=" ++ show (mfGen mf) ++ "\n" ++
                "snapshot=" ++ mfSnapshot mf ++ "\n" ++
                "wal=" ++ mfWal mf ++ "\n"
  atomicWriteFile (manifestPath dir) (BS.pack (map (toEnum . fromEnum) payload))

currentSnapshotPath :: FilePath -> IO FilePath
currentSnapshotPath dir = do
  m <- readManifest dir
  case m of
    Right mf -> pure (mfSnapshot mf)
    Left _ -> findHighestSnapshot dir

currentWalPath :: FilePath -> IO FilePath
currentWalPath dir = do
  m <- readManifest dir
  case m of
    Right mf -> pure (mfWal mf)
    Left _ -> findHighestWal dir

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
  h <- ensureWalHeader path
  case h of
    Left err -> pure (Left err)
    Right () -> do
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
  atomicWriteFile path walHeader

rotateSnapshotAndWal :: FilePath -> Snapshot -> IO (Either String ())
rotateSnapshotAndWal dir snap = do
  createDirectoryIfMissing True (dir </> "snapshots")
  createDirectoryIfMissing True (dir </> "wal")
  case encodeSnapshot snap of
    Left err -> pure (Left (show err))
    Right bytes -> do
      gen <- nextGeneration dir
      let snapFile = dir </> "snapshots" </> ("snap." ++ show gen ++ ".csnp")
      let walFile = dir </> "wal" </> ("wal." ++ show gen ++ ".wal")
      r1 <- atomicWriteFile snapFile bytes
      case r1 of
        Left err -> pure (Left ("snapshot rotate failed: " ++ err))
        Right () -> do
          r2 <- atomicWriteFile walFile walHeader
          case r2 of
            Left err -> pure (Left ("wal reset failed: " ++ err))
            Right () -> do
              let mf = Manifest { mfGen = gen, mfSnapshot = snapFile, mfWal = walFile }
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
      h <- ensureWalHeader path
      case h of
        Left err -> pure (Left err)
        Right () -> do
          bytes <- BS.readFile path
          case runGetOrFail getEntries (BL.fromStrict bytes) of
            Left (_, _, err) -> pure (Left ("wal parse error: " ++ err))
            Right (_, _, entries) ->
              case foldM applyOne snap entries of
                Left err -> pure (Left err)
                Right res -> pure (Right res)
  where
    getEntries = do
      header <- getByteString (BS.length walHeader)
      if header /= walHeader
        then fail "wal header mismatch"
        else go []
    go acc = do
      done <- isEmpty
      if done
        then pure (reverse acc)
        else do
          len <- getWord32le
          crc <- getWord32le
          payload <- getByteString (fromIntegral len)
          if crc /= crc32 payload
            then fail "wal checksum mismatch"
            else go (payload : acc)

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
  bracket (openFd path ReadWrite Nothing defaultFileFlags) closeFd fsync

fsyncDir :: FilePath -> IO ()
fsyncDir dir =
  bracket (openFd dir ReadOnly Nothing defaultFileFlags) closeFd fsync

writeBlobAtomic :: FilePath -> BS.ByteString -> IO (Either String ())
writeBlobAtomic = atomicWriteFile

nextGeneration :: FilePath -> IO Int
nextGeneration dir = do
  m <- readManifest dir
  case m of
    Right mf -> pure (mfGen mf + 1)
    Left _ -> do
      g <- findHighestGen dir
      pure (g + 1)

findHighestGen :: FilePath -> IO Int
findHighestGen dir = do
  snaps <- listDirectory (dir </> "snapshots") `catchDefault` []
  wals <- listDirectory (dir </> "wal") `catchDefault` []
  let snapG = mapMaybe (extractGen "snap." ".csnp") snaps
  let walG = mapMaybe (extractGen "wal." ".wal") wals
  let common = filter (`elem` walG) snapG
  pure (if null common then 0 else maximum common)
  where
    mapMaybe f = foldr (\x acc -> maybe acc (:acc) (f x)) []
    extractGen pre suf name =
      if pre `List.isPrefixOf` name && List.isSuffixOf suf name
        then readMaybe (take (length name - length pre - length suf) (drop (length pre) name))
        else Nothing
    catchDefault io def = catchIOError io (\_ -> pure def)

findHighestSnapshot :: FilePath -> IO FilePath
findHighestSnapshot dir = do
  g <- findHighestGen dir
  if g <= 0
    then pure (snapshotPath dir)
    else pure (dir </> "snapshots" </> ("snap." ++ show g ++ ".csnp"))

findHighestWal :: FilePath -> IO FilePath
findHighestWal dir = do
  g <- findHighestGen dir
  if g <= 0
    then pure (walPath dir)
    else pure (dir </> "wal" </> ("wal." ++ show g ++ ".wal"))

walHeader :: BS.ByteString
walHeader =
  let magic = BS.pack [0x50,0x4d,0x57,0x41,0x4c] -- "PMWAL"
      ver = BL.toStrict (runPut (putWord16le 1))
  in magic <> ver

ensureWalHeader :: FilePath -> IO (Either String ())
ensureWalHeader path = do
  exists <- doesFileExist path
  if not exists
    then BS.writeFile path walHeader >> pure (Right ())
    else do
      sz <- getFileSize path
      if sz < fromIntegral (BS.length walHeader)
        then pure (Left "wal header missing")
        else do
          header <- BS.readFile path
          if BS.take (BS.length walHeader) header /= walHeader
            then pure (Left "wal header mismatch")
            else pure (Right ())

walEntryCount :: FilePath -> IO (Either String Int)
walEntryCount dir = do
  path <- currentWalPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Right 0)
    else do
      h <- ensureWalHeader path
      case h of
        Left err -> pure (Left err)
        Right () -> do
          bytes <- BS.readFile path
          case runGetOrFail countEntries (BL.fromStrict bytes) of
            Left (_, _, err) -> pure (Left ("wal parse error: " ++ err))
            Right (_, _, n) -> pure (Right n)
  where
    countEntries = do
      _ <- getByteString (BS.length walHeader)
      go 0
    go n = do
      done <- isEmpty
      if done
        then pure n
        else do
          len <- getWord32le
          _ <- getWord32le
          _ <- getByteString (fromIntegral len)
          go (n + 1)

crc32 :: BS.ByteString -> Word32
crc32 bs = BS.foldl' step 0xFFFFFFFF bs `xor` 0xFFFFFFFF
  where
    step crc b =
      let idx = fromIntegral ((crc `xor` fromIntegral b) .&. 0xFF)
      in (crc `shiftR` 8) `xor` table !! idx

    table = map mk [0..255]
    mk i = List.foldl' (\c _ -> if c .&. 1 == 1 then 0xEDB88320 `xor` (c `shiftR` 1) else c `shiftR` 1) (fromIntegral i) [1..8]
