module Snapshot.Reconcile.Types
  ( Region(..)
  , ReconcileError(..)
  ) where

import Data.Int (Int64)
import Data.Word (Word8, Word32, Word64)

data Region = Region
  { regShard :: !Word32
  , regTickStart :: !Word64
  , regTickEnd :: !Word64
  , regEntityMin :: !Int64
  , regEntityMax :: !Int64
  , regPriority :: !Word8
  }
  deriving (Eq, Show)

data ReconcileError
  = ErrOverlapMismatch !Int64
  | ErrNonCovering ![Region]
  | ErrOutOfRange !Int64 !Region
  | ErrIncompatibleRegion !Region !Region
  | ErrInternalInvariant !Region !Region
  deriving (Eq, Show)
