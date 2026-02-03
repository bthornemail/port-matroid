module Snapshot.Decode
  ( decodeSnapshot
  , decodeSnapshotWith
  , decodeSection
  , decodeSectionWith
  , Limits(..)
  , defaultLimits
  ) where

import Snapshot.Types
import Snapshot.Limits (Limits(..), defaultLimits)
import Snapshot.Errors (DecodeError(..))

import Control.Monad (when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Binary.Get
import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import qualified Data.Text.Normalize as N
import Data.Word (Word8, Word32, Word64)
import qualified Crypto.Hash.SHA256 as SHA

magicCSNP :: ByteString
magicCSNP = BS.pack [0x43, 0x53, 0x4E, 0x50]

magicCSPT :: ByteString
magicCSPT = BS.pack [0x43, 0x53, 0x50, 0x54]

 

-- | Decode and strictly validate a canonical CSNP snapshot.
decodeSnapshot :: ByteString -> Either DecodeError Snapshot
decodeSnapshot = decodeSnapshotWith defaultLimits

-- | Decode and validate with explicit limits.
decodeSnapshotWith :: Limits -> ByteString -> Either DecodeError Snapshot
decodeSnapshotWith limits bs
  | BS.length bs < 64 = Left ErrTooShort
  | BS.length bs > maxSnapshotBytes limits = Left ErrSnapshotTooLarge
  | otherwise =
      case runGetOrFail (parser limits) (BL.fromStrict bs) of
        Left (_, _, _) -> Left ErrTruncatedInput
        Right (remaining, _, result) ->
          case result of
            Left err -> Left err
            Right snap ->
              if not (BL.null remaining)
                then Left ErrTrailingBytes
                else verifyHash bs snap

-- | Decode and strictly validate a canonical CSPT section.
decodeSection :: ByteString -> Either DecodeError Section
decodeSection = decodeSectionWith defaultLimits

-- | Decode CSPT with explicit limits.
decodeSectionWith :: Limits -> ByteString -> Either DecodeError Section
decodeSectionWith limits bs
  | BS.length bs < 73 = Left ErrTooShort
  | BS.length bs > maxSnapshotBytes limits = Left ErrSnapshotTooLarge
  | otherwise =
      case runGetOrFail (parserSection limits) (BL.fromStrict bs) of
        Left (_, _, _) -> Left ErrTruncatedInput
        Right (remaining, _, result) ->
          case result of
            Left err -> Left err
            Right sec ->
              if not (BL.null remaining)
                then Left ErrTrailingBytes
                else verifySectionHash bs sec

parser :: Limits -> Get (Either DecodeError Snapshot)
parser limits = runExceptT (parserE limits)

type GetD = ExceptT DecodeError Get

parserE :: Limits -> GetD Snapshot
parserE limits = do
  magic <- liftGet (getByteString 4)
  when (magic /= magicCSNP) $
    throwE ErrInvalidMagic

  version <- liftGet getWord16le
  subversion <- liftGet getWord16le
  flags <- liftGet getWord32le
  tick <- liftGet getWord64le
  count <- liftGet getWord64le
  reserved <- liftGet getWord32le

  when (version /= 1 || subversion /= 0) $
    throwE ErrUnsupportedVersion
  when (flags /= 1) $
    throwE ErrInvalidFlags
  when (reserved /= 0) $
    throwE ErrReservedNonZero
  when (count > maxEntities limits) $
    throwE ErrEntityCountExceeded

  ents <- decodeEntities limits count

  hashBytes <- liftGet (getByteString 32)
  return $ Snapshot tick ents (Hash hashBytes)

parserSectionE :: Limits -> GetD Section
parserSectionE limits = do
  magic <- liftGet (getByteString 4)
  when (magic /= magicCSPT) $
    throwE ErrInvalidMagic

  shard <- liftGet getWord32le
  tickStart <- liftGet getWord64le
  tickEnd <- liftGet getWord64le
  entityMin <- liftGet getInt64le
  entityMax <- liftGet getInt64le
  priority <- liftGet getWord8

  when (tickStart >= tickEnd) $
    throwE ErrTickRangeInvalid
  when (entityMin > entityMax) $
    throwE ErrEntityRangeInvalid

  ents <- decodeEntitiesUntilHash limits entityMin entityMax

  hashBytes <- liftGet (getByteString 32)
  return $ Section shard tickStart tickEnd entityMin entityMax priority ents (Hash hashBytes)

verifyHash :: ByteString -> Snapshot -> Either DecodeError Snapshot
verifyHash bs snap@(Snapshot _ _ (Hash h))
  | BS.length h /= 32 = Left ErrHashLength
  | otherwise =
      let preimage = BS.take (BS.length bs - 32) bs
          expected = SHA.hash preimage
      in if expected == h
           then Right snap
           else Left ErrHashMismatch

verifySectionHash :: ByteString -> Section -> Either DecodeError Section
verifySectionHash bs sec@(Section _ _ _ _ _ _ _ (Hash h))
  | BS.length h /= 32 = Left ErrHashLength
  | otherwise =
      let preimage = BS.take (BS.length bs - 32) bs
          expected = SHA.hash preimage
      in if expected == h
           then Right sec
           else Left ErrHashMismatch

decodeEntities :: Limits -> Word64 -> GetD [Entity]
decodeEntities limits n = go n Nothing []
  where
    go 0 _ acc = return (reverse acc)
    go k prev acc = do
      e <- decodeEntity limits
      case prev of
        Just p | entId e <= p -> throwE ErrEntityIdsNotAscending
        _ -> go (k - 1) (Just $ entId e) (e : acc)

decodeEntitiesUntilHash :: Limits -> Int64 -> Int64 -> GetD [Entity]
decodeEntitiesUntilHash limits minId maxId = go 0 Nothing []
  where
    go count prev acc = do
      when (count >= maxEntities limits) $
        throwE ErrEntityCountExceeded
      remainingBytes <- liftGet remaining
      if remainingBytes == 32
        then return (reverse acc)
        else if remainingBytes < 32
          then throwE ErrTruncatedInput
          else do
            e <- decodeEntity limits
            when (entId e < minId || entId e > maxId) $
              throwE ErrEntityOutOfRange
            case prev of
              Just p | entId e <= p -> throwE ErrEntityIdsNotAscending
              _ -> go (count + 1) (Just $ entId e) (e : acc)

decodeEntity :: Limits -> GetD Entity
decodeEntity limits = do
  eid <- liftGet getInt64le
  typeLen <- liftGet getWord32le
  when (typeLen > maxStringBytes limits) $
    throwE ErrEntityTypeTooLong
  typeLenInt <- safeLen typeLen
  entTypeBytes <- liftGet (getByteString typeLenInt)
  validateUtf8Nfc entTypeBytes

  dataLen <- liftGet getWord32le
  dataLenInt <- safeLen dataLen
  compMap <- withIsolate dataLenInt (decodeComponentMap limits)

  return $ Entity eid entTypeBytes compMap

decodeComponentMap :: Limits -> GetD ComponentMap
decodeComponentMap limits = do
  count <- liftGet getWord32le
  when (count > maxComponentPairs limits) $
    throwE ErrComponentCountExceeded
  pairs <- decodePairs limits count Nothing []
  remainingBytes <- liftGet remaining
  when (remainingBytes /= 0) $
    throwE ErrComponentLengthMismatch
  return $ ComponentMap (Map.fromDistinctAscList pairs)

decodePairs :: Limits -> Word32 -> Maybe ByteString -> [(ByteString, Value)] -> GetD [(ByteString, Value)]
decodePairs _ 0 _ acc = return (reverse acc)
decodePairs limits n prev acc = do
  keyLen <- liftGet getWord32le
  when (keyLen == 0 || keyLen > 255) $
    throwE ErrKeyLengthInvalid
  keyLenInt <- safeLen keyLen
  keyBytes <- liftGet (getByteString keyLenInt)
  validateKey keyBytes
  validateUtf8Nfc keyBytes
  case prev of
    Just p | keyBytes <= p -> throwE ErrKeysNotAscending
    _ -> return ()
  valueType <- liftGet getWord8
  value <- decodeValue limits valueType
  decodePairs limits (n - 1) (Just keyBytes) ((keyBytes, value) : acc)

decodeValue :: Limits -> Word8 -> GetD Value
decodeValue limits t =
  case t of
    0x01 -> VInt64 <$> liftGet getInt64le
    0x02 -> VUInt64 <$> liftGet getWord64le
    0x03 -> do
      w <- liftGet getWord32le
      validateFloat32Bits w
      return (VFloat32 w)
    0x04 -> do
      w <- liftGet getWord64le
      validateFloat64Bits w
      return (VFloat64 w)
    0x05 -> do
      strLen <- liftGet getWord32le
      when (strLen > maxStringBytes limits) $
        throwE ErrStringTooLong
      strLenInt <- safeLen strLen
      bytes <- liftGet (getByteString strLenInt)
      validateUtf8Nfc bytes
      return (VString bytes)
    0x06 -> do
      b <- liftGet getWord8
      case b of
        0 -> return (VBool False)
        1 -> return (VBool True)
        _ -> throwE ErrInvalidBool
    0x07 -> return VNull
    _ -> throwE (ErrUnknownValueType t)

validateUtf8Nfc :: ByteString -> GetD ()
validateUtf8Nfc bs =
  case decodeUtf8' bs of
    Left _ -> throwE ErrInvalidUtf8
    Right t -> do
      when (BS.isPrefixOf (BS.pack [0xEF, 0xBB, 0xBF]) bs) $
        throwE ErrUtf8Bom
      let norm = N.normalize N.NFC t
          bsNorm = encodeUtf8 norm
      when (bsNorm /= bs) $
        throwE ErrNotNfc

validateKey :: ByteString -> GetD ()
validateKey bs
  | BS.null bs = throwE ErrKeyInvalid
  | not (isAsciiAlpha (BS.head bs) || BS.head bs == 0x5f) = throwE ErrKeyInvalid
  | BS.any (not . isAsciiIdent) bs = throwE ErrKeyInvalid
  | otherwise = return ()
  where
    isAsciiAlpha w = (w >= 0x41 && w <= 0x5a) || (w >= 0x61 && w <= 0x7a)
    isAsciiDigit w = w >= 0x30 && w <= 0x39
    isAsciiIdent w = isAsciiAlpha w || isAsciiDigit w || w == 0x5f

validateFloat32Bits :: Word32 -> GetD ()
validateFloat32Bits w = do
  let sign = w `shiftR` 31
      exponent = (w `shiftR` 23) .&. 0xff
      mantissa = w .&. 0x7fffff
  when (exponent == 0xff) $
    throwE ErrFloatNaNOrInfinity
  when (exponent == 0 && mantissa == 0 && sign == 1) $
    throwE ErrFloatNegativeZero

validateFloat64Bits :: Word64 -> GetD ()
validateFloat64Bits w = do
  let sign = w `shiftR` 63
      exponent = (w `shiftR` 52) .&. 0x7ff
      mantissa = w .&. 0x000fffffffffffff
  when (exponent == 0x7ff) $
    throwE ErrFloatNaNOrInfinity
  when (exponent == 0 && mantissa == 0 && sign == 1) $
    throwE ErrFloatNegativeZero

safeLen :: (Integral a) => a -> GetD Int
safeLen n
  | n > fromIntegral (maxBound :: Int) = throwE ErrLengthOverflow
  | otherwise = return (fromIntegral n)

liftGet :: Get a -> GetD a
liftGet = ExceptT . fmap Right

withIsolate :: Int -> GetD a -> GetD a
withIsolate n action = ExceptT (isolate n (runExceptT action))
parserSection :: Limits -> Get (Either DecodeError Section)
parserSection limits = runExceptT (parserSectionE limits)
