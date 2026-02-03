{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Snapshot.Types where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Word (Word8, Word32, Word64)
import GHC.Generics (Generic)

-- | Canonical snapshot
-- All invariants are enforced by the decoder.
data Snapshot = Snapshot
  { snapTick :: !Word64
  , snapEntities :: ![Entity] -- already sorted, validated
  , snapHash :: !Hash
  }
  deriving (Eq, Show, Generic)

-- | Canonical CSPT section
data Section = Section
  { secShard :: !Word32
  , secTickStart :: !Word64
  , secTickEnd :: !Word64
  , secEntityMin :: !Int64
  , secEntityMax :: !Int64
  , secPriority :: !Word8
  , secEntities :: ![Entity] -- already sorted, validated
  , secHash :: !Hash
  }
  deriving (Eq, Show, Generic)

-- | Canonical entity
data Entity = Entity
  { entId :: !Int64
  , entType :: !ByteString -- UTF-8 NFC already validated
  , entData :: !ComponentMap
  }
  deriving (Eq, Show, Generic)

-- | Canonical component map (sorted by key)
newtype ComponentMap = ComponentMap (Map ByteString Value)
  deriving (Eq, Show, Generic)

-- | Canonical value domain
data Value
  = VInt64 !Int64
  | VUInt64 !Word64
  | VFloat32 !Word32 -- stored as raw bits
  | VFloat64 !Word64 -- stored as raw bits
  | VString !ByteString
  | VBool !Bool
  | VNull
  deriving (Eq, Show, Generic)

newtype Hash = Hash ByteString
  deriving (Eq, Show, Generic)
