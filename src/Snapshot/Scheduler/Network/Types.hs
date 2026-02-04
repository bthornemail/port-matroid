module Snapshot.Scheduler.Network.Types
  ( MessageType(..)
  , NetError(..)
  , PeerId
  , encodeCell
  , decodeCell
  ) where

import Snapshot.Scheduler.Types (Cell(..))
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Word (Word16, Word32, Word64, Word8)

type PeerId = ByteString

data MessageType
  = MsgRoutingContext
  | MsgWorkDigest
  | MsgWorkRequest
  | MsgWorkBundle
  deriving (Eq, Show)

data NetError
  = NetErrMalformed
  | NetErrUnknownType
  | NetErrNonCanonical
  | NetErrInvalid
  deriving (Eq, Show)

encodeCell :: Cell -> (Word32, Word64, Word64, Int64, Int64, Word8)
encodeCell (Cell shard t0 t1 e0 e1 tier) = (shard, t0, t1, e0, e1, tier)

decodeCell :: (Word32, Word64, Word64, Int64, Int64, Word8) -> Cell
decodeCell (shard, t0, t1, e0, e1, tier) = Cell shard t0 t1 e0 e1 tier
