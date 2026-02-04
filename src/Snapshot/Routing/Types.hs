module Snapshot.Routing.Types
  ( RoutingParams(..)
  , RoutingContext(..)
  , RoutingError(..)
  , peerIdLength
  , routingSaltLength
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word16, Word64, Word8)

data RoutingParams = RoutingParams
  { routingVersion :: Word16
  , replicationFactor :: Word8
  , routingSalt :: ByteString
  } deriving (Eq, Show)

data RoutingContext = RoutingContext
  { routingEpoch :: Word64
  , routingParams :: RoutingParams
  , routingPeers :: [ByteString]
  } deriving (Eq, Show)

data RoutingError
  = RoutErrBadVersion
  | RoutErrInvalidParams
  | RoutErrInvalidPeerSet
  | RoutErrInvalidPeerId
  | RoutErrMalformed
  deriving (Eq, Show)

peerIdLength :: Int
peerIdLength = 32

routingSaltLength :: Int
routingSaltLength = 32
