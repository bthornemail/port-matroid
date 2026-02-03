module Snapshot.Limits
  ( Limits(..)
  , defaultLimits
  ) where

import Data.Word (Word32, Word64)

-- | Encoder/decoder limits. These are enforced as hard maximums.
data Limits = Limits
  { maxEntities :: !Word64
  , maxStringBytes :: !Word32
  , maxSnapshotBytes :: !Int
  , maxComponentPairs :: !Word32
  }
  deriving (Eq, Show)

-- | Default limits meet the minimum interoperability requirements.
defaultLimits :: Limits
defaultLimits = Limits
  { maxEntities = 1000000
  , maxStringBytes = 16 * 1024 * 1024
  , maxSnapshotBytes = 256 * 1024 * 1024
  , maxComponentPairs = 1000000
  }
