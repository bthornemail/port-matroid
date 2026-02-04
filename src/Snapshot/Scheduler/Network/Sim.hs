module Snapshot.Scheduler.Network.Sim
  ( SimNode(..)
  , stepSim
  , convergeSteps
  , expectedUnion
  ) where

import Snapshot.Routing.Core (routeShard)
import Snapshot.Routing.Types (RoutingContext)
import Snapshot.Scheduler.Network.Types (PeerId, NetError(..))
import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Union (unionWorkSets)

import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Word (Word32)

data SimNode = SimNode
  { simPeer :: PeerId
  , simWork :: CanonicalWorkSet
  } deriving (Eq, Show)

stepSim :: RoutingContext -> [SimNode] -> Either NetError [SimNode]
stepSim ctx nodes = do
  let ordered = List.sortBy (\a b -> compare (simPeer a) (simPeer b)) nodes
  let initial = Map.fromList [ (simPeer n, simWork n) | n <- ordered ]
  msgs <- buildMessages ctx ordered
  final <- foldl applyMsg (Right initial) msgs
  let result = [ SimNode p w | (p, w) <- Map.toList final ]
  return result
  where
    applyMsg acc (peer, items) =
      case acc of
        Left err -> Left err
        Right mp ->
          case Map.lookup peer mp of
            Nothing -> Left NetErrInvalid
            Just ws ->
              case unionWorkSets (unCanonicalWorkSet ws) items of
                Left _ -> Left NetErrInvalid
                Right ws' -> Right (Map.insert peer ws' mp)

buildMessages :: RoutingContext -> [SimNode] -> Either NetError [(PeerId, [WorkItem])]
buildMessages ctx nodes = do
  let ordered = List.sortBy (\a b -> compare (simPeer a) (simPeer b)) nodes
  let msgLists = map (messagesForNode ctx) ordered
  concat <$> sequence msgLists

messagesForNode :: RoutingContext -> SimNode -> Either NetError [(PeerId, [WorkItem])]
messagesForNode ctx node = do
  let shardMap = shardItems (simWork node)
  let shards = Map.keys shardMap
  let shardMsgs = map (messagesForShard ctx (simPeer node) shardMap) shards
  concat <$> sequence shardMsgs

messagesForShard :: RoutingContext -> PeerId -> Map.Map Word32 [WorkItem] -> Word32 -> Either NetError [(PeerId, [WorkItem])]
messagesForShard ctx sender shardMap shard = do
  reps <- case routeShard ctx shard of
    Left _ -> Left NetErrInvalid
    Right xs -> Right xs
  if sender `elem` reps
    then case Map.lookup shard shardMap of
      Nothing -> Right []
      Just items ->
        let ordered = List.sort reps
        in Right [ (peer, items) | peer <- ordered ]
    else Right []

shardItems :: CanonicalWorkSet -> Map.Map Word32 [WorkItem]
shardItems ws =
  let items = unCanonicalWorkSet ws
  in foldl insert Map.empty items
  where
    insert mp w =
      let shard = cellShard (workCell w)
      in Map.insertWith (++) shard [w] mp

convergeSteps :: Int -> RoutingContext -> [SimNode] -> Either NetError [SimNode]
convergeSteps steps ctx nodes =
  if steps <= 0
    then Right nodes
    else do
      next <- stepSim ctx nodes
      convergeSteps (steps - 1) ctx next

expectedUnion :: [SimNode] -> CanonicalWorkSet
expectedUnion nodes =
  canonicalizeWorkSet (concatMap (unCanonicalWorkSet . simWork) nodes)
