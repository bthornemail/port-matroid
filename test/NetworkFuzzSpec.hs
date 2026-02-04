{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Applicative (liftA2)
import Control.Exception (bracket)
import Control.Monad (foldM, replicateM, when, zipWithM)
import Data.Binary.Put (putWord64le, runPut)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.List (find)
import Data.Word (Word64)
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removeDirectoryRecursive
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, run)
import Text.Read (readMaybe)

import Runtime.Net.Gossip
import Runtime.Net.Gossip.Types
import Runtime.Store
  ( appendWal
  , loadSnapshot
  , replayWalWith
  , rotateSnapshotAndWal
  )
import Snapshot.Types (Hash(..), Snapshot(..))
import Snapshot.Universe.Core (encodeStream, opcodeAdvanceTick)
import Snapshot.Universe.Types (Instruction(..))

-- ----------------------------
-- Types
-- ----------------------------

data NodeStatus = Alive | Crashed
  deriving (Eq, Show)

data NodeSim = NodeSim
  { nsId :: !NodeId
  , nsEpoch :: !Word64
  , nsEnv :: !GossipEnv
  , nsStatus :: !NodeStatus
  }

data LinkState = Up | Down
  deriving (Eq, Show)

data Message = Message
  { mFrom :: !NodeId
  , mTo :: !NodeId
  , mBytes :: !ByteString
  }
  deriving (Eq, Show)

data SimWorld = SimWorld
  { wNodes :: ![NodeSim]
  , wLinks :: ![((NodeId, NodeId), LinkState)]
  , wQueue :: ![Message]
  }

data Action
  = ActDeliver
  | ActDrop
  | ActDup
  | ActCorrupt
  | ActShuffle
  | ActPartition NodeId NodeId
  | ActHeal NodeId NodeId
  | ActCrash NodeId
  | ActRestart NodeId
  | ActNodeStep NodeId
  deriving (Eq, Show)

-- ----------------------------
-- Generators
-- ----------------------------

genAction :: [NodeId] -> Gen Action
genAction ids = frequency
  [ (30, pure ActDeliver)
  , (10, pure ActDrop)
  , (10, pure ActDup)
  , (10, pure ActCorrupt)
  , (10, pure ActShuffle)
  , (8, liftA2 ActPartition pick pick)
  , (8, liftA2 ActHeal pick pick)
  , (6, ActCrash <$> pick)
  , (6, ActRestart <$> pick)
  , (12, ActNodeStep <$> pick)
  ]
  where
    pick = elements ids

genActions :: [NodeId] -> Int -> Gen [Action]
genActions ids n = replicateM n (genAction ids)

-- ----------------------------
-- Snapshot helpers
-- ----------------------------

emptySnapshot :: Snapshot
emptySnapshot = Snapshot 0 [] (Hash (BS.replicate 32 0))

mkAdvanceBatch :: Word64 -> ByteString
mkAdvanceBatch d =
  let payload = BL.toStrict (runPut (putWord64le d))
      instr = Instruction opcodeAdvanceTick 0 payload
  in case encodeStream [instr] of
      Left _ -> BS.empty
      Right bs -> bs

-- ----------------------------
-- Message processing
-- ----------------------------

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

-- ----------------------------
-- World step
-- ----------------------------

stepWorld :: SimWorld -> Action -> IO SimWorld
stepWorld w act =
  case act of
    ActDeliver ->
      case wQueue w of
        [] -> pure w
        (m:rest) ->
          if not (linkUp w (mFrom m) (mTo m))
            then pure w { wQueue = rest }
            else do
              let receiver = findNode (mTo m) (wNodes w)
              let sender = findNode (mFrom m) (wNodes w)
              case (sender, receiver) of
                (Just s, Just r) | nsStatus r == Alive -> do
                  outs <- processMsg s r (mBytes m)
                  let newMsgs = [ Message (mTo m) (mFrom m) b | b <- outs ]
                  pure w { wQueue = rest ++ newMsgs }
                _ -> pure w { wQueue = rest }
    ActDrop ->
      case wQueue w of
        [] -> pure w
        (_:rest) -> pure w { wQueue = rest }
    ActDup ->
      case wQueue w of
        [] -> pure w
        (m:rest) -> pure w { wQueue = m:m:rest }
    ActCorrupt ->
      case wQueue w of
        [] -> pure w
        (m:rest) -> pure w { wQueue = m { mBytes = corruptOne (mBytes m) } : rest }
    ActShuffle ->
      pure w { wQueue = reverse (wQueue w) }
    ActPartition a b ->
      pure w { wLinks = setLink Down a b (wLinks w) }
    ActHeal a b ->
      pure w { wLinks = setLink Up a b (wLinks w) }
    ActCrash nid ->
      pure w { wNodes = updateNode nid (\n -> n { nsStatus = Crashed }) (wNodes w) }
    ActRestart nid ->
      case findNode nid (wNodes w) of
        Nothing -> pure w
        Just n ->
          if nsStatus n /= Crashed
            then pure w
            else do
              ok <- restartNode n
              if ok
                then pure w { wNodes = updateNode nid (\x -> x { nsStatus = Alive }) (wNodes w) }
                else pure w
    ActNodeStep nid ->
      case findNode nid (wNodes w) of
        Nothing -> pure w
        Just n ->
          if nsStatus n /= Alive
            then pure w
            else do
              msgs <- emitHello n (wNodes w)
              pure w { wQueue = wQueue w ++ msgs }

-- ----------------------------
-- Property
-- ----------------------------

prop_converges_after_heal :: Property
prop_converges_after_heal = monadicIO $ do
  steps <- run $ readEnvInt "NETWORK_FUZZ_STEPS" 50
  nodesN <- run $ readEnvInt "NETWORK_FUZZ_NODES" 2
  res <- run $ withWorld nodesN $ \world0 -> do
    let ids = map nsId (wNodes world0)
    actions <- generate (genActions ids steps)
    worldN <- foldM stepWorld world0 actions
    healed <- healAll worldN
    drained <- drainQueue healed 100
    sums <- mapM (\n -> mkSummary (nsId n) (nsEpoch n) (nsEnv n)) (wNodes drained)
    pure sums
  let hashes = [ sSnapHash s | Right s <- res ]
  assert (not (null hashes) && all (== head hashes) hashes)

-- ----------------------------
-- World helpers
-- ----------------------------

withWorld :: Int -> (SimWorld -> IO a) -> IO a
withWorld n action = do
  nodes <- createNodes n
  let links = [ ((a, b), Up) | a <- map nsId nodes, b <- map nsId nodes, a /= b ]
  let world0 = SimWorld nodes links []
  world1 <- seedHellos world0
  action world1

createNodes :: Int -> IO [NodeSim]
createNodes n = do
  dirs <- replicateM n mkTempDir
  let ids = map (NodeId . fromIntegral) [1..n]
  zipWithM initOne ids dirs
  where
    initOne nid dir = do
      _ <- rotateSnapshotAndWal dir emptySnapshot
      when (nid == NodeId 1) $ do
        _ <- appendWal dir (mkAdvanceBatch 1)
        pure ()
      let env = GossipEnv dir 65536 (1024 * 1024)
      pure (NodeSim nid 1 env Alive)

seedHellos :: SimWorld -> IO SimWorld
seedHellos w = do
  msgs <- fmap concat $ mapM (\n -> emitHello n (wNodes w)) (wNodes w)
  pure w { wQueue = wQueue w ++ msgs }

emitHello :: NodeSim -> [NodeSim] -> IO [Message]
emitHello n peers = do
  s <- mkSummary (nsId n) (nsEpoch n) (nsEnv n)
  case s of
    Left _ -> pure []
    Right sumry ->
      pure [ Message (nsId n) (nsId p) (encodeMsg (MHello sumry))
           | p <- peers
           , nsId p /= nsId n
           ]

drainQueue :: SimWorld -> Int -> IO SimWorld
drainQueue w0 limit = go 0 w0
  where
    go i w
      | i >= limit = pure w
      | null (wQueue w) = pure w
      | otherwise = stepWorld w ActDeliver >>= go (i + 1)

healAll :: SimWorld -> IO SimWorld
healAll w = pure w { wLinks = [ (k, Up) | (k, _) <- wLinks w ] }

linkUp :: SimWorld -> NodeId -> NodeId -> Bool
linkUp w a b =
  case lookup (a, b) (wLinks w) of
    Just Up -> True
    _ -> False

setLink :: LinkState -> NodeId -> NodeId -> [((NodeId, NodeId), LinkState)] -> [((NodeId, NodeId), LinkState)]
setLink st a b links =
  map (\(k, v) -> if k == (a, b) then ((a, b), st) else (k, v)) links

findNode :: NodeId -> [NodeSim] -> Maybe NodeSim
findNode nid = find (\n -> nsId n == nid)

updateNode :: NodeId -> (NodeSim -> NodeSim) -> [NodeSim] -> [NodeSim]
updateNode nid f = map (\n -> if nsId n == nid then f n else n)

restartNode :: NodeSim -> IO Bool
restartNode n = do
  snap <- loadSnapshot (geDataDir (nsEnv n))
  case snap of
    Left _ -> pure False
    Right s -> do
      r <- replayWalWith False (geDataDir (nsEnv n)) s
      pure (either (const False) (const True) r)

-- ----------------------------
-- Temp dir helpers
-- ----------------------------

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

-- ----------------------------
-- Main
-- ----------------------------

main :: IO ()
main = do
  maxS <- readEnvInt "NETWORK_FUZZ_MAX" 100
  quickCheckWith stdArgs { maxSuccess = maxS } prop_converges_after_heal

readEnvInt :: String -> Int -> IO Int
readEnvInt key def = do
  v <- lookupEnv key
  case v >>= readMaybe of
    Just n | n > 0 -> pure n
    _ -> pure def

