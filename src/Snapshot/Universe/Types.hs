module Snapshot.Universe.Types
  ( Instruction(..)
  , Opcode(..)
  , AuthorityMask(..)
  , Result(..)
  , HaltReason(..)
  , InstructionLimits(..)
  , defaultInstructionLimits
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word16, Word32, Word64)

data Instruction = Instruction
  { instrOpcode :: !Opcode
  , instrFlags :: !Word16
  , instrPayload :: !ByteString
  }
  deriving (Eq, Show)

newtype Opcode = Opcode Word16
  deriving (Eq, Ord, Show)

newtype AuthorityMask = AuthorityMask Word64
  deriving (Eq, Ord, Show)

data Result
  = Next
  | Halt !HaltReason
  deriving (Eq, Show)

data HaltReason
  = ErrUnknownOpcode
  | ErrUnauthorized
  | ErrEntityExists
  | ErrEntityMissing
  | ErrInvalidKey
  | ErrInvalidValue
  | ErrInvalidType
  | ErrInvalidTick
  | ErrCanonicalViolation
  | ErrLimitExceeded
  | ErrInternalInvariant
  | ErrMalformedInstruction
  deriving (Eq, Show)

data InstructionLimits = InstructionLimits
  { maxInstructionSize :: !Word32
  , maxPayloadSize :: !Word32
  , maxInstructionsPerStream :: !Word32
  }
  deriving (Eq, Show)

defaultInstructionLimits :: InstructionLimits
defaultInstructionLimits = InstructionLimits
  { maxInstructionSize = 1024 * 1024
  , maxPayloadSize = 1024 * 1024
  , maxInstructionsPerStream = 100000
  }
