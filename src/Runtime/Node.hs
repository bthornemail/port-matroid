module Runtime.Node
  ( NodeState(..)
  , initNode
  , handleMessage
  , tickOnce
  ) where

import Runtime.Config (Config(..), LogLevel(..))
import Runtime.Store (appendWal, rotateSnapshotAndWal)
import Runtime.Log (logMsg)

import Snapshot.Types (Snapshot)
import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Union (unionWorkSets)
import Snapshot.Scheduler.Core (scheduleStep)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Scheduler.Network.Decode (decodeMessage)
import Snapshot.Scheduler.Network.Types (MessageType(..), NetError(..))
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..))
import Snapshot.Routing.Types (RoutingContext)

import qualified Data.ByteString as BS

data NodeState = NodeState
  { nodeConfig :: Config
  , nodeRouting :: RoutingContext
  , nodeSnapshot :: Snapshot
  , nodeWorkSet :: CanonicalWorkSet
  , nodeWalCount :: Int
  } deriving (Eq, Show)

initNode :: Config -> RoutingContext -> Snapshot -> NodeState
initNode cfg ctx snap = NodeState
  { nodeConfig = cfg
  , nodeRouting = ctx
  , nodeSnapshot = snap
  , nodeWorkSet = canonicalizeWorkSet []
  , nodeWalCount = 0
  }

handleMessage :: NodeState -> BS.ByteString -> IO (Either NetError NodeState)
handleMessage st msg = do
  case decodeMessage msg of
    Left e -> pure (Left e)
    Right (mt, payload) ->
      case mt of
        MsgWorkBundle -> do
          case decodeWorkSet payload of
            Left _ -> pure (Left NetErrMalformed)
            Right ws ->
              case unionWorkSets (unCanonicalWorkSet (nodeWorkSet st)) ws of
                Left _ -> pure (Left NetErrInvalid)
                Right w' -> pure (Right st { nodeWorkSet = w' })
        MsgWorkDigest -> pure (Right st)
        MsgWorkRequest -> pure (Right st)
        MsgRoutingContext -> pure (Left NetErrInvalid)

tickOnce :: NodeState -> IO (Either String NodeState)
tickOnce st = do
  let cfg = nodeConfig st
  case scheduleStep defaultParams defaultState (unCanonicalWorkSet (nodeWorkSet st)) of
    Left err -> pure (Left ("scheduleStep failed: " ++ show err))
    Right (batch, _) ->
      case decodeStream batch of
        Left err -> pure (Left ("decodeStream failed: " ++ show err))
        Right instrs ->
          case applyInstructions (nodeSnapshot st) (AuthorityMask 0xF) instrs of
            (Halt r, _) -> pure (Left ("applyInstructions halted: " ++ show r))
            (Next, snap') -> do
              if cfgReadonly cfg
                then pure (Right st { nodeSnapshot = snap' })
                else do
                  _ <- appendWal (cfgDataDir cfg) batch
                  let walCount' = nodeWalCount st + 1
                  if walCount' >= 1000
                    then do
                      _ <- rotateSnapshotAndWal (cfgDataDir cfg) snap'
                      logMsg cfg Info "snapshot rotation"
                      pure (Right st { nodeSnapshot = snap', nodeWorkSet = canonicalizeWorkSet [], nodeWalCount = 0 })
                    else do
                      logMsg cfg Info "applied batch"
                      pure (Right st { nodeSnapshot = snap', nodeWorkSet = canonicalizeWorkSet [], nodeWalCount = walCount' })
