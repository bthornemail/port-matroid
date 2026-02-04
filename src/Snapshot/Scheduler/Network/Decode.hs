module Snapshot.Scheduler.Network.Decode
  ( decodeMessage
  ) where

import Snapshot.Scheduler.Network.Types

import Data.Binary.Get
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL

decodeMessage :: ByteString -> Either NetError (MessageType, ByteString)
decodeMessage bs =
  case runGetOrFail getMsg (BL.fromStrict bs) of
    Left _ -> Left NetErrMalformed
    Right (rest, _, v) ->
      if BL.null rest then Right v else Left NetErrMalformed
  where
    getMsg = do
      t <- getWord16le
      payload <- getRemainingLazyByteString
      mt <- case t of
        0x0001 -> pure MsgRoutingContext
        0x0002 -> pure MsgWorkDigest
        0x0003 -> pure MsgWorkRequest
        0x0004 -> pure MsgWorkBundle
        _ -> fail "unknown"
      pure (mt, BL.toStrict payload)
