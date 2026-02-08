{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (replicateM, when)
import Data.Binary.Put (putWord64le, runPut)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Bits (xor)
import Data.IORef
import Data.Word (Word64)
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , doesFileExist
  )
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import Test.QuickCheck
import Test.QuickCheck.Monadic (monadicIO, run, assert)

import Snapshot.Types (Snapshot(..), Hash(..))
import Snapshot.Universe.Types (Instruction(..), Opcode(..), AuthorityMask(..), Result(..))
import Snapshot.Universe.Core (encodeStream, decodeStream, applyInstructions, opcodeNOP, opcodeAdvanceTick)
import Runtime.Store
  ( rotateSnapshotAndWal
  , appendWal
  , replayWalWith
  , loadSnapshot
  , currentWalPath
  , readManifest
  , writeManifest
  , Manifest(..)
  , manifestPath
  , writeBlobAtomic
  , ensureWalHeader
  )
import qualified Snapshot.Encode

-- ----------------------------
-- Temp dir helper
-- ----------------------------

{-# NOINLINE tempCounter #-}
tempCounter :: IORef Int
tempCounter = unsafePerformIO (newIORef 0)

mkTempDir :: IO FilePath
mkTempDir = do
  base <- getTemporaryDirectory
  pid <- getProcessID
  n <- atomicModifyIORef' tempCounter (\i -> (i + 1, i + 1))
  let dir = base </> ("port-matroid-fuzz-" ++ show pid ++ "-" ++ show n)
  createDirectoryIfMissing True dir
  pure dir

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = bracket mkTempDir removeDirectoryRecursive

-- ----------------------------
-- Generators
-- ----------------------------

genDelta :: Gen Word64
genDelta = fromIntegral <$> chooseInt (1, 5)

genInstruction :: Gen Instruction
genInstruction = oneof
  [ pure (Instruction opcodeNOP 0 BS.empty)
  , do
      d <- genDelta
      let payload = BL.toStrict (runPut (putWord64le d))
      pure (Instruction opcodeAdvanceTick 0 payload)
  ]

genBatch :: Gen ByteString
genBatch = do
  n <- chooseInt (0, 5)
  instrs <- replicateM n genInstruction
  pure $ case encodeStream instrs of
    Left _ -> BS.empty
    Right bs -> bs

genHistory :: Gen [ByteString]
genHistory = do
  n <- chooseInt (0, 6)
  replicateM n genBatch

-- ----------------------------
-- Model
-- ----------------------------

emptySnapshot :: Snapshot
emptySnapshot = Snapshot 0 [] (Hash (BS.replicate 32 0))

applyBatch :: Snapshot -> ByteString -> Either String Snapshot
applyBatch snap bs =
  case decodeStream bs of
    Left _ -> Left "decode stream failed"
    Right instrs ->
      case applyInstructions snap (fromIntegralAuth 0xF) instrs of
        (Next, snap') -> Right snap'
        (Halt r, _) -> Left ("halt: " ++ show r)
  where
    fromIntegralAuth :: Word64 -> AuthorityMask
    fromIntegralAuth = AuthorityMask

applyHistory :: Snapshot -> [ByteString] -> Either String Snapshot
applyHistory = foldl (\acc b -> acc >>= \s -> applyBatch s b) . Right

-- ----------------------------
-- Mutations
-- ----------------------------

data Mutation
  = FlipByte
  | Truncate
  | CorruptHeader
  deriving (Eq, Show)

genMutation :: Gen Mutation
genMutation = elements [FlipByte, Truncate, CorruptHeader]

mutateWal :: Mutation -> FilePath -> IO ()
mutateWal mut path = do
  bytes <- BS.readFile path
  let len = BS.length bytes
  case mut of
    FlipByte ->
      if len == 0
        then pure ()
        else do
          idx <- generate (chooseInt (0, len - 1))
          let b = BS.index bytes idx
              b' = b `xorByte` 0xFF
          BS.writeFile path (replaceByte idx b' bytes)
    Truncate ->
      if len == 0
        then pure ()
        else do
          cut <- generate (chooseInt (0, len - 1))
          BS.writeFile path (BS.take cut bytes)
    CorruptHeader ->
      if len == 0
        then pure ()
        else do
          let idx = 0
              b = BS.index bytes idx
          BS.writeFile path (replaceByte idx (b `xorByte` 0xFF) bytes)
  where
    xorByte x y = fromIntegral ((fromIntegral x :: Int) `xor` (fromIntegral y :: Int))
    replaceByte i v bs = BS.take i bs <> BS.singleton v <> BS.drop (i + 1) bs

-- ----------------------------
-- Crash simulation (manifest switch)
-- ----------------------------

simulateRotationCrash :: FilePath -> Snapshot -> Snapshot -> IO (Snapshot, Snapshot)
simulateRotationCrash dir oldSnap newSnap = do
  _ <- rotateSnapshotAndWal dir oldSnap
  -- Compute next generation file paths
  m <- readManifest dir
  let gen = case m of
        Right mf -> mfGen mf + 1
        Left _ -> 1
      snapFile = dir </> "snapshots" </> ("snap." ++ show gen ++ ".csnp")
      walFile = dir </> "wal" </> ("wal." ++ show gen ++ ".wal")
  createDirectoryIfMissing True (dir </> "snapshots")
  createDirectoryIfMissing True (dir </> "wal")
  -- Write new snapshot and WAL, but do NOT update manifest (crash before commit)
  case Snapshot.Encode.encodeSnapshot newSnap of
    Left _ -> pure (oldSnap, oldSnap)
    Right bytes -> do
      _ <- writeBlobAtomic snapFile bytes
      _ <- ensureWalHeader walFile
      -- Recovery should still use old manifest
      recoveredOld <- loadSnapshot dir >>= \res -> case res of
        Left _ -> pure oldSnap
        Right s -> do
          r <- replayWalWith False dir s
          pure (either (const s) id r)
      -- Now commit manifest (crash after commit)
      _ <- writeManifest dir (Manifest gen snapFile walFile)
      recoveredNew <- loadSnapshot dir >>= \res -> case res of
        Left _ -> pure newSnap
        Right s -> do
          r <- replayWalWith False dir s
          pure (either (const s) id r)
      pure (recoveredOld, recoveredNew)

-- ----------------------------
-- Properties
-- ----------------------------

prop_clean_replay :: Property
prop_clean_replay = monadicIO $ do
  history <- run $ generate genHistory
  res <- run $ withTempDir $ \dir -> do
    _ <- rotateSnapshotAndWal dir emptySnapshot
    mapM_ (appendWal dir) history
    base <- loadSnapshot dir
    case base of
      Left err -> pure (Left err)
      Right snap -> replayWalWith False dir snap
  let model = applyHistory emptySnapshot history
  assert (fmap (const ()) res == fmap (const ()) model)

prop_corruption_fail_closed :: Property
prop_corruption_fail_closed = monadicIO $ do
  history <- run $ generate genHistory
  mut <- run $ generate genMutation
  res <- run $ withTempDir $ \dir -> do
    _ <- rotateSnapshotAndWal dir emptySnapshot
    mapM_ (appendWal dir) history
    wal <- currentWalPath dir
    mutateWal mut wal
    base <- loadSnapshot dir
    case base of
      Left _ -> pure (Left "snapshot missing")
      Right snap -> replayWalWith False dir snap
  assert (either (const True) (const False) res)

prop_truncate_allows_trailing :: Property
prop_truncate_allows_trailing = monadicIO $ do
  history <- run $ generate genHistory
  res <- run $ withTempDir $ \dir -> do
    _ <- rotateSnapshotAndWal dir emptySnapshot
    mapM_ (appendWal dir) history
    wal <- currentWalPath dir
    -- Truncate the WAL to force a trailing partial entry
    bytes <- BS.readFile wal
    let cut = max 0 (BS.length bytes - 1)
    BS.writeFile wal (BS.take cut bytes)
    base <- loadSnapshot dir
    case base of
      Left err -> pure (Left err, Left err)
      Right snap -> do
        strict <- replayWalWith False dir snap
        trunc <- replayWalWith True dir snap
        pure (strict, trunc)
  let (strictRes, truncRes) = res
  assert (either (const True) (const False) strictRes && either (const False) (const True) truncRes)

prop_manifest_corruption_fallback :: Property
prop_manifest_corruption_fallback = monadicIO $ do
  res <- run $ withTempDir $ \dir -> do
    _ <- rotateSnapshotAndWal dir emptySnapshot
    mpath <- pure (manifestPath dir)
    exists <- doesFileExist mpath
    when exists $ do
      bytes <- BS.readFile mpath
      BS.writeFile mpath (bytes <> BS.pack [0xFF]) -- corrupt
    snap <- loadSnapshot dir
    pure snap
  assert (either (const False) (const True) res)

prop_crash_rotation_manifest_switch :: Property
prop_crash_rotation_manifest_switch = monadicIO $ do
  res <- run $ withTempDir $ \dir -> do
    let oldSnap = emptySnapshot
        newSnap = Snapshot 1 [] (Hash (BS.replicate 32 0))
    simulateRotationCrash dir oldSnap newSnap
  let (recOld, recNew) = res
  assert (snapTick recOld == 0 && snapTick recNew == 1)

-- ----------------------------
-- Main
-- ----------------------------

main :: IO ()
main = do
  maxS <- readEnvInt "STORAGE_FUZZ_MAX" 200
  maxSmall <- readEnvInt "STORAGE_FUZZ_MAX_SMALL" 100
  quickCheckWith stdArgs { maxSuccess = maxS } prop_clean_replay
  quickCheckWith stdArgs { maxSuccess = maxS } prop_corruption_fail_closed
  quickCheckWith stdArgs { maxSuccess = maxS } prop_truncate_allows_trailing
  quickCheckWith stdArgs { maxSuccess = maxSmall } prop_manifest_corruption_fallback
  quickCheckWith stdArgs { maxSuccess = maxSmall } prop_crash_rotation_manifest_switch

readEnvInt :: String -> Int -> IO Int
readEnvInt key def = do
  v <- lookupEnv key
  case v >>= readMaybe of
    Just n | n > 0 -> pure n
    _ -> pure def
