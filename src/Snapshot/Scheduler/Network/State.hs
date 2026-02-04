module Snapshot.Scheduler.Network.State
  ( NodeState(..)
  , initState
  , stepMessage
  ) where

import Snapshot.Routing.Types (RoutingContext(..))
import Snapshot.Scheduler.Network.Decode (decodeMessage)
import Snapshot.Scheduler.Network.Digest (decodeWorkDigestPayload)
import Snapshot.Scheduler.Network.Authority (verifyReplicaDigestAuthority)
import Snapshot.Scheduler.Network.Epoch (EpochState(..), adoptEpoch)
import Snapshot.Scheduler.Network.Types

import Data.ByteString (ByteString)

data NodeState = NodeState
  { nodeRoutingCtx :: RoutingContext
  , nodeEpoch :: EpochState
  } deriving (Eq, Show)

initState :: RoutingContext -> NodeState
initState ctx = NodeState
  { nodeRoutingCtx = ctx
  , nodeEpoch = EpochState { currentEpoch = routingEpoch ctx }
  }

stepMessage :: NodeState -> PeerId -> ByteString -> Either NetError NodeState
stepMessage st sender msgBytes = do
  (mt, payload) <- decodeMessage msgBytes
  case mt of
    MsgRoutingContext ->
      case adoptEpoch (nodeEpoch st) payload of
        Left e -> Left e
        Right (ep, ctx) -> Right st { nodeEpoch = ep, nodeRoutingCtx = ctx }
    MsgWorkDigest -> do
      (shard, _digest) <- decodeWorkDigestPayload payload
      verifyReplicaDigestAuthority (nodeRoutingCtx st) shard sender
      Right st
    MsgWorkRequest -> Left NetErrInvalid
    MsgWorkBundle -> Left NetErrInvalid
