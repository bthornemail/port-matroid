module Snapshot.Routing.Decode
  ( decodeRoutingContext
  ) where

import Snapshot.Routing.Types
import Snapshot.Routing.Core (validateContext)

import Data.Binary.Get
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Control.Monad (replicateM)

decodeRoutingContext :: ByteString -> Either RoutingError RoutingContext
decodeRoutingContext bs =
  case runGetOrFail getContext (BL.fromStrict bs) of
    Left _ -> Left RoutErrMalformed
    Right (rest, _, ctx) ->
      if BL.null rest
        then validateContext ctx
        else Left RoutErrMalformed
  where
    getContext = do
      version <- getWord16le
      epoch <- getWord64le
      repl <- getWord8
      salt <- getByteString routingSaltLength
      count <- getWord32le
      peers <- replicateM (fromIntegral count) (getByteString peerIdLength)
      let params = RoutingParams
            { routingVersion = version
            , replicationFactor = repl
            , routingSalt = salt
            }
      return RoutingContext
        { routingEpoch = epoch
        , routingParams = params
        , routingPeers = peers
        }
