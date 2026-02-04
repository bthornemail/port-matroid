module Main (main) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Core (routeShard)
import Snapshot.Scheduler.Network.Encode (encodeMessage)
import Snapshot.Scheduler.Network.State
import Snapshot.Scheduler.Network.Types

import qualified Data.ByteString as BS

main :: IO ()
main = do
  ctx0Bytes <- BS.readFile "test/golden-network/routing-epoch0.ctx"
  ctx1Bytes <- BS.readFile "test/golden-network/routing-epoch1.ctx"
  ctx0 <- case decodeRoutingContext ctx0Bytes of
    Left e -> error ("decode ctx0 failed: " ++ show e)
    Right c -> pure c
  ctx1 <- case decodeRoutingContext ctx1Bytes of
    Left e -> error ("decode ctx1 failed: " ++ show e)
    Right c -> pure c
  let st0 = initState ctx0
  let msgCtx1 = encodeMessage MsgRoutingContext ctx1Bytes
  st1 <- case stepMessage st0 (BS.replicate 32 0x00) msgCtx1 of
    Left e -> error ("expected epoch adopt, got: " ++ show e)
    Right s -> pure s
  if nodeEpoch st1 /= nodeEpoch (initState ctx1)
    then error "epoch not updated in state machine"
    else pure ()

  digestMsg <- BS.readFile "test/golden-network/digest-basic.msg"
  reps <- case routeShard ctx0 0 of
    Left e -> error ("routeShard failed: " ++ show e)
    Right xs -> pure xs
  case reps of
    [] -> error "replica set empty"
    (p0:_) -> do
      case stepMessage st0 p0 digestMsg of
        Right _ -> pure ()
        Left e -> error ("expected digest accept, got: " ++ show e)
      let outsider = BS.replicate 32 0xFF
      case stepMessage st0 outsider digestMsg of
        Left NetErrInvalid -> pure ()
        Left e -> error ("expected NetErrInvalid, got: " ++ show e)
        Right _ -> error "outsider digest accepted"
  putStrLn "OK"
