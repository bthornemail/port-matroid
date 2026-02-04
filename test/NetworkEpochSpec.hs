module Main (main) where

import Snapshot.Scheduler.Network.Epoch
import Snapshot.Scheduler.Network.Types (NetError(..))

import qualified Data.ByteString as BS

main :: IO ()
main = do
  let st0 = EpochState { currentEpoch = 0 }
  ctx0 <- BS.readFile "test/golden-network/routing-epoch0.ctx"
  ctx1 <- BS.readFile "test/golden-network/routing-epoch1.ctx"
  case adoptEpoch st0 ctx1 of
    Right (st1, _) ->
      if currentEpoch st1 /= 1
        then error "epoch not updated"
        else pure ()
    Left e -> error ("expected adopt, got: " ++ show e)
  let st1 = EpochState { currentEpoch = 1 }
  case adoptEpoch st1 ctx0 of
    Left NetErrInvalid -> pure ()
    Left e -> error ("expected NetErrInvalid, got: " ++ show e)
    Right _ -> error "unexpectedly adopted lower epoch"
  case adoptEpoch st0 (BS.take 4 ctx1) of
    Left NetErrMalformed -> pure ()
    Left e -> error ("expected NetErrMalformed, got: " ++ show e)
    Right _ -> error "unexpectedly adopted malformed context"
  putStrLn "OK"
