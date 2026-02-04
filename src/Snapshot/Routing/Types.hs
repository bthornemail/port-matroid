module Snapshot.Routing.Types
  ( RoutingParams(..)
  , RoutingContext(..)
  , RoutingError(..)
  , routingErrorToCode
  , codeToRoutingError
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

routingErrorToCode :: RoutingError -> Word16
routingErrorToCode err =
  case err of
    RoutErrBadVersion -> 0x0001
    RoutErrInvalidParams -> 0x0002
    RoutErrInvalidPeerSet -> 0x0003
    RoutErrInvalidPeerId -> 0x0004
    RoutErrMalformed -> 0x0005

codeToRoutingError :: Word16 -> Maybe RoutingError
codeToRoutingError code =
  case code of
    0x0001 -> Just RoutErrBadVersion
    0x0002 -> Just RoutErrInvalidParams
    0x0003 -> Just RoutErrInvalidPeerSet
    0x0004 -> Just RoutErrInvalidPeerId
    0x0005 -> Just RoutErrMalformed
    _ -> Nothing

peerIdLength :: Int
peerIdLength = 32

routingSaltLength :: Int
routingSaltLength = 32
