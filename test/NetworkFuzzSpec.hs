{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Monad (replicateM, foldM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word64)
import Data.Bits (xor)
import System.Environment (lookupEnv)
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removeDirectoryRecursive
  )
import System.FilePath ((</>))
import Control.Exception (bracket)
import System.Posix.Process (getProcessID)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Test.QuickCheck
import Test.QuickCheck.Monadic (monadicIO, run, assert)

import Runtime.Net.Gossip.Types
import Runtime.Net.Gossip
import Runtime.Store
  ( rotateSnapshotAndWal
  , appendWal
  )
import Snapshot.Types (Snapshot(..), Hash(..))
import Snapshot.Universe.Core (encodeStream, opcodeAdvanceTick)
import Snapshot.Universe.Types (Instruction(..))
import Data.Binary.Put (putWord64le, runPut)
import qualified Data.ByteString.Lazy as BL
import Text.Read (readMaybe)

data NodeSim = NodeSim
  { nsId :: !NodeId
  , nsEpoch :: !Word64
  , nsEnv :: !GossipEnv
  }

data Action
  = ActDeliver
  | ActDrop
  | ActDup
  | ActCorrupt
  | ActShuffle
  deriving (Eq, Show)

genAction :: Gen Action
genAction = elements [ActDeliver, ActDrop, ActDup, ActCorrupt, ActShuffle]

genActions :: Int -> Gen [Action]
genActions n = replicateM n genAction

emptySnapshot :: Snapshot
emptySnapshot = Snapshot 0 [] (Hash (BS.replicate 32 0))

mkAdvanceBatch :: Word64 -> ByteString
mkAdvanceBatch d =
  let payload = BL.toStrict (runPut (putWord64le d))
      instr = Instruction opcodeAdvanceTick 0 payload
  in case encodeStream [instr] of
      Left _ -> BS.empty
      Right bs -> bs

processMsg :: NodeSim -> NodeSim -> ByteString -> IO [ByteString]
processMsg sender receiver raw =
  case decodeMsg raw of
    Left _ -> pure []
    Right msg -> case msg of
      MHello otherSum -> do
        mySum <- mkSummary (nsId receiver) (nsEpoch receiver) (nsEnv receiver)
        case mySum of
          Left _ -> pure []
          Right me ->
            case decidePull me otherSum of
              Nothing -> pure []
              Just pr -> pure [encodeMsg pr]
      MPullReq{} -> do
        mySum <- mkSummary (nsId receiver) (nsEpoch receiver) (nsEnv receiver)
        case mySum of
          Left _ -> pure []
          Right me -> do
            res <- handlePullReq (nsEnv receiver) me msg
            case res of
              Left n -> pure [encodeMsg (MNack n)]
              Right out -> pure [encodeMsg out]
      MPullSnap{} -> do
        res <- applyPullSnap (nsEnv receiver) msg
        case res of
          Left n -> pure [encodeMsg (MNack n)]
          Right () -> pure []
      MPullWal{} -> do
        res <- applyPullWal (nsEnv receiver) msg
        case res of
          Left n -> pure [encodeMsg (MNack n)]
          Right () -> pure []
      MNack{} -> pure []

corruptOne :: ByteString -> ByteString
corruptOne bs =
  if BS.null bs
    then bs
    else
      let b = BS.head bs
      in BS.cons (b `xorByte` 0xFF) (BS.tail bs)
  where
    xorByte x y = fromIntegral ((fromIntegral x :: Int) `xor` (fromIntegral y :: Int))

stepWorld :: NodeSim -> NodeSim -> [ByteString] -> Action -> IO [ByteString]
stepWorld n1 n2 queue act =
  case act of
    ActDeliver ->
      case queue of
        [] -> pure []
        (m:rest) -> do
          out1 <- processMsg n1 n2 m
          out2 <- processMsg n2 n1 m
          pure (rest ++ out1 ++ out2)
    ActDrop ->
      case queue of
        [] -> pure []
        (_:rest) -> pure rest
    ActDup ->
      case queue of
        [] -> pure []
        (m:rest) -> pure (m:m:rest)
    ActCorrupt ->
      case queue of
        [] -> pure []
        (m:rest) -> pure (corruptOne m : rest)
    ActShuffle ->
      pure (reverse queue)

prop_converges_after_heal :: Property
prop_converges_after_heal = monadicIO $ do
  steps <- run $ readEnvInt "NETWORK_FUZZ_STEPS" 50
  actions <- run $ generate (genActions steps)
  res <- run $ withTwoNodes $ \(n1, n2) -> do
    let queue0 = []
    -- seed with HELLO from both nodes
    s1 <- mkSummary (nsId n1) (nsEpoch n1) (nsEnv n1)
    s2 <- mkSummary (nsId n2) (nsEpoch n2) (nsEnv n2)
    let queue1 = case (s1, s2) of
          (Right a, Right b) -> [encodeMsg (MHello a), encodeMsg (MHello b)]
          _ -> []
    queueN <- foldM (stepWorld n1 n2) queue1 actions
    -- final heal: deliver remaining messages deterministically
    finalQ <- foldM (stepWorld n1 n2) queueN (replicate 10 ActDeliver)
    sum1 <- mkSummary (nsId n1) (nsEpoch n1) (nsEnv n1)
    sum2 <- mkSummary (nsId n2) (nsEpoch n2) (nsEnv n2)
    pure (sum1, sum2, finalQ)
  let (s1, s2, _) = res
  assert (case (s1, s2) of
            (Right a, Right b) -> sSnapHash a == sSnapHash b
            _ -> False)

withTwoNodes :: ((NodeSim, NodeSim) -> IO a) -> IO a
withTwoNodes action = do
  withTempDir $ \dir1 ->
    withTempDir $ \dir2 -> do
      _ <- rotateSnapshotAndWal dir1 emptySnapshot
      _ <- rotateSnapshotAndWal dir2 emptySnapshot
      -- node1 is ahead by one tick
      _ <- appendWal dir1 (mkAdvanceBatch 1)
      let env1 = GossipEnv dir1 65536 (1024 * 1024)
      let env2 = GossipEnv dir2 65536 (1024 * 1024)
      let n1 = NodeSim (NodeId 1) 1 env1
      let n2 = NodeSim (NodeId 2) 1 env2
      action (n1, n2)

main :: IO ()
main = do
  maxS <- readEnvInt "NETWORK_FUZZ_MAX" 100
  quickCheckWith stdArgs { maxSuccess = maxS } prop_converges_after_heal

-- Temp dir helpers

{-# NOINLINE tempCounter #-}
tempCounter :: IORef Int
tempCounter = unsafePerformIO (newIORef 0)

mkTempDir :: IO FilePath
mkTempDir = do
  base <- getTemporaryDirectory
  pid <- getProcessID
  n <- atomicModifyIORef' tempCounter (\i -> (i + 1, i + 1))
  let dir = base </> ("port-matroid-netfuzz-" ++ show pid ++ "-" ++ show n)
  createDirectoryIfMissing True dir
  pure dir

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = bracket mkTempDir removeDirectoryRecursive

readEnvInt :: String -> Int -> IO Int
readEnvInt key def = do
  v <- lookupEnv key
  case v >>= readMaybe of
    Just n | n > 0 -> pure n
    _ -> pure def
