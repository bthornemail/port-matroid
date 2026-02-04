module Snapshot.Scheduler.Network.Encode
  ( encodeMessage
  , encodeU16le
  ) where

import Snapshot.Scheduler.Network.Types

import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word16)

encodeU16le :: Word16 -> ByteString
encodeU16le w = BL.toStrict $ runPut (putWord16le w)

tag :: MessageType -> Word16
tag mt =
  case mt of
    MsgRoutingContext -> 0x0001
    MsgWorkDigest -> 0x0002
    MsgWorkRequest -> 0x0003
    MsgWorkBundle -> 0x0004

encodeMessage :: MessageType -> ByteString -> ByteString
encodeMessage mt payload =
  BL.toStrict $ runPut $ do
    putWord16le (tag mt)
    putByteString payload
