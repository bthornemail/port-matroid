module Snapshot.Routing.Core
  ( validateContext
  , routeShard
  , scorePeer
  ) where

import Snapshot.Routing.Types

import Crypto.Hash.SHA256 (hash)
import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (sort, sortBy)
import Data.Word (Word32)

validateContext :: RoutingContext -> Either RoutingError RoutingContext
validateContext ctx = do
  let params = routingParams ctx
  validateParams params (length (routingPeers ctx))
  validatePeerSet (routingPeers ctx)
  return ctx

validateParams :: RoutingParams -> Int -> Either RoutingError ()
validateParams params peerCount
  | routingVersion params /= 1 = Left RoutErrBadVersion
  | BS.length (routingSalt params) /= routingSaltLength = Left RoutErrInvalidParams
  | replicationFactor params < 1 = Left RoutErrInvalidParams
  | replicationFactor params > fromIntegral peerCount = Left RoutErrInvalidParams
  | peerCount <= 0 = Left RoutErrInvalidParams
  | otherwise = Right ()

validatePeerSet :: [ByteString] -> Either RoutingError ()
validatePeerSet peers
  | any invalidPeer peers = Left RoutErrInvalidPeerId
  | not (isStrictlySorted peers) = Left RoutErrInvalidPeerSet
  | otherwise = Right ()
  where
    invalidPeer p = BS.length p /= peerIdLength

isStrictlySorted :: [ByteString] -> Bool
isStrictlySorted peers = peers == sort peers && noDup peers
  where
    noDup [] = True
    noDup [_] = True
    noDup (a:b:rest) = a < b && noDup (b:rest)

routeShard :: RoutingContext -> Word32 -> Either RoutingError [ByteString]
routeShard ctx shard = do
  _ <- validateContext ctx
  let peers = routingPeers ctx
  let params = routingParams ctx
  let scored = [ (scorePeer params shard p, p) | p <- peers ]
  let ordered = sortByScore scored
  let count = fromIntegral (replicationFactor params)
  return (map snd (take count ordered))

scorePeer :: RoutingParams -> Word32 -> ByteString -> ByteString
scorePeer params shard peer =
  let input = BL.toStrict $ runPut $ do
        putByteString (routingSalt params)
        putByteString peer
        putWord32le shard
  in hash input

sortByScore :: [(ByteString, ByteString)] -> [(ByteString, ByteString)]
sortByScore = sortBy cmp
  where
    cmp (s1, p1) (s2, p2)
      | s1 < s2 = GT
      | s1 > s2 = LT
      | p1 < p2 = LT
      | p1 > p2 = GT
      | otherwise = EQ
