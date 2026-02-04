module Snapshot.Routing.Encode
  ( encodeRoutingContext
  ) where

import Snapshot.Routing.Types
import Snapshot.Routing.Core (validateContext)

import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

encodeRoutingContext :: RoutingContext -> Either RoutingError ByteString
encodeRoutingContext ctx = do
  _ <- validateContext ctx
  return $ BL.toStrict $ runPut $ do
    let params = routingParams ctx
    putWord16le (routingVersion params)
    putWord64le (routingEpoch ctx)
    putWord8 (replicationFactor params)
    putByteString (routingSalt params)
    let peers = routingPeers ctx
    putWord32le (fromIntegral (length peers))
    mapM_ putByteString peers
