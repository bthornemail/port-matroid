module Snapshot.Scheduler.Network.Epoch
  ( EpochState(..)
  , adoptEpoch
  ) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Types (RoutingContext(..))
import Snapshot.Scheduler.Network.Types (NetError(..))

import Data.ByteString (ByteString)
import Data.Word (Word64)

data EpochState = EpochState
  { currentEpoch :: Word64
  } deriving (Eq, Show)

adoptEpoch :: EpochState -> ByteString -> Either NetError (EpochState, RoutingContext)
adoptEpoch st ctxBytes = do
  ctx <- case decodeRoutingContext ctxBytes of
    Left _ -> Left NetErrMalformed
    Right c -> Right c
  if routingEpoch ctx > currentEpoch st
    then Right (st { currentEpoch = routingEpoch ctx }, ctx)
    else Left NetErrInvalid
