module Snapshot.Scheduler.Network.Authority
  ( verifyReplicaDigestAuthority
  ) where

import Snapshot.Scheduler.Network.Types
import Snapshot.Routing.Core (routeShard)
import Snapshot.Routing.Types (RoutingContext)
import Data.Word (Word32)

verifyReplicaDigestAuthority :: RoutingContext -> Word32 -> PeerId -> Either NetError ()
verifyReplicaDigestAuthority ctx shard sender = do
  reps <- case routeShard ctx shard of
    Left _ -> Left NetErrInvalid
    Right xs -> Right xs
  if sender `elem` reps then Right () else Left NetErrInvalid
