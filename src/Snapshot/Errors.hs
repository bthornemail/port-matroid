module Snapshot.Errors
  ( DecodeError(..)
  , EncodeError(..)
  ) where

import Data.Word (Word8)

-- | Structured decoder errors for protocol compliance.
data DecodeError
  = ErrTooShort
  | ErrTrailingBytes
  | ErrInvalidMagic
  | ErrUnsupportedVersion
  | ErrInvalidFlags
  | ErrReservedNonZero
  | ErrEntityCountExceeded
  | ErrEntityIdsNotAscending
  | ErrEntityTypeTooLong
  | ErrTickRangeInvalid
  | ErrEntityRangeInvalid
  | ErrEntityOutOfRange
  | ErrComponentCountExceeded
  | ErrComponentLengthMismatch
  | ErrKeyLengthInvalid
  | ErrKeyInvalid
  | ErrKeysNotAscending
  | ErrInvalidUtf8
  | ErrUtf8Bom
  | ErrNotNfc
  | ErrStringTooLong
  | ErrUnknownValueType Word8
  | ErrInvalidBool
  | ErrFloatNaNOrInfinity
  | ErrFloatNegativeZero
  | ErrLengthOverflow
  | ErrHashLength
  | ErrHashMismatch
  | ErrSnapshotTooLarge
  | ErrTruncatedInput
  deriving (Eq, Show)

-- | Structured encoder errors for protocol compliance.
data EncodeError
  = EncodeEntityCountExceeded
  | EncodeSnapshotTooLarge
  | EncodeHashLength
  | EncodeEntityIdsNotAscending
  | EncodeEntityTypeTooLong
  | EncodeTickRangeInvalid
  | EncodeEntityRangeInvalid
  | EncodeEntityOutOfRange
  | EncodeComponentCountExceeded
  | EncodeKeyLengthInvalid
  | EncodeKeyInvalid
  | EncodeInvalidUtf8
  | EncodeUtf8Bom
  | EncodeNotNfc
  | EncodeStringTooLong
  | EncodeUnknownValueType
  | EncodeFloatNaNOrInfinity
  | EncodeFloatNegativeZero
  | EncodeLengthOverflow
  deriving (Eq, Show)
