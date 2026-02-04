module Main (main) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Core (routeShard)
import Snapshot.Scheduler.Network.Authority (verifyReplicaDigestAuthority)
import Snapshot.Scheduler.Network.Types (NetError(..), PeerId)

import qualified Data.ByteString as BS

main :: IO ()
main = do
  ctxBytes <- BS.readFile "test/golden-network/routing-epoch0.ctx"
  ctx <- case decodeRoutingContext ctxBytes of
    Left e -> error ("decodeRoutingContext failed: " ++ show e)
    Right c -> pure c
  reps <- case routeShard ctx 0 of
    Left e -> error ("routeShard failed: " ++ show e)
    Right xs -> pure xs
  case reps of
    [] -> error "replicas empty"
    (p0:_) -> do
      case verifyReplicaDigestAuthority ctx 0 p0 of
        Right () -> pure ()
        Left e -> error ("expected accept, got: " ++ show e)
      let outsider :: PeerId
          outsider = BS.replicate 32 0xFF
      case verifyReplicaDigestAuthority ctx 0 outsider of
        Left NetErrInvalid -> pure ()
        Left e -> error ("expected NetErrInvalid, got: " ++ show e)
        Right () -> error "outsider incorrectly accepted"
  putStrLn "OK"
