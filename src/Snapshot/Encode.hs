module Snapshot.Encode
  ( encodeSnapshot
  , encodeSnapshotWith
  , encodeSection
  , encodeSectionWith
  ) where

import Snapshot.Types
import Snapshot.Limits (Limits(..), defaultLimits)
import Snapshot.Errors (EncodeError(..))

import Control.Monad (when)
import Data.Binary.Put
import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (sortOn)
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

-- | Encode a canonical CSNP snapshot.
encodeSnapshot :: Snapshot -> Either EncodeError ByteString
encodeSnapshot = encodeSnapshotWith defaultLimits

-- | Encode with explicit limits.
encodeSnapshotWith :: Limits -> Snapshot -> Either EncodeError ByteString
encodeSnapshotWith limits snap = do
  validateHashLength snap
  let ents0 = snapEntities snap
  when (fromIntegral (length ents0) > maxEntities limits) $
    Left EncodeEntityCountExceeded

  let ents = sortOn entId ents0
  ensureStrictAscendingEntities ents

  entityBytes <- traverse (encodeEntity limits) ents
  let entityTable = BS.concat entityBytes
  header <- encodeHeader (snapTick snap) (fromIntegral (length ents))

  let preimage = BS.concat [header, entityTable]
      hash = SHA.hash preimage
      full = BS.concat [preimage, hash]

  when (BS.length full > maxSnapshotBytes limits) $
    Left EncodeSnapshotTooLarge

  return full

-- | Encode a canonical CSPT section.
encodeSection :: Section -> Either EncodeError ByteString
encodeSection = encodeSectionWith defaultLimits

-- | Encode CSPT with explicit limits.
encodeSectionWith :: Limits -> Section -> Either EncodeError ByteString
encodeSectionWith limits sec = do
  validateHashLengthSection sec
  let ents0 = secEntities sec
  when (fromIntegral (length ents0) > maxEntities limits) $
    Left EncodeEntityCountExceeded

  when (secTickStart sec >= secTickEnd sec) $
    Left EncodeTickRangeInvalid
  when (secEntityMin sec > secEntityMax sec) $
    Left EncodeEntityRangeInvalid

  let ents = sortOn entId ents0
  ensureStrictAscendingEntities ents
  mapM_ (ensureEntityInRange (secEntityMin sec) (secEntityMax sec)) ents

  entityBytes <- traverse (encodeEntity limits) ents
  let entityTable = BS.concat entityBytes
  header <- encodeSectionHeader sec

  let preimage = BS.concat [header, entityTable]
      hash = SHA.hash preimage
      full = BS.concat [preimage, hash]

  when (BS.length full > maxSnapshotBytes limits) $
    Left EncodeSnapshotTooLarge

  return full

encodeHeader :: Word64 -> Word64 -> Either EncodeError ByteString
encodeHeader tick count =
  return $ BL.toStrict $ runPut $ do
    putByteString magicCSNP
    putWord16le 1
    putWord16le 0
    putWord32le 1
    putWord64le tick
    putWord64le count
    putWord32le 0

encodeSectionHeader :: Section -> Either EncodeError ByteString
encodeSectionHeader sec =
  return $ BL.toStrict $ runPut $ do
    putByteString magicCSPT
    putWord32le (secShard sec)
    putWord64le (secTickStart sec)
    putWord64le (secTickEnd sec)
    putInt64le (secEntityMin sec)
    putInt64le (secEntityMax sec)
    putWord8 (secPriority sec)

encodeEntity :: Limits -> Entity -> Either EncodeError ByteString
encodeEntity limits ent = do
  typeBytes <- normalizeUtf8Nfc (entType ent)
  when (BS.length typeBytes > fromIntegral (maxStringBytes limits)) $
    Left EncodeEntityTypeTooLong

  typeLen <- lenWord32 "Entity type length" (BS.length typeBytes)
  compBytes <- encodeComponentMap limits (entData ent)
  dataLen <- lenWord32 "Component data length" (BS.length compBytes)

  return $ BL.toStrict $ runPut $ do
    putInt64le (entId ent)
    putWord32le typeLen
    putByteString typeBytes
    putWord32le dataLen
    putByteString compBytes

encodeComponentMap :: Limits -> ComponentMap -> Either EncodeError ByteString
encodeComponentMap limits (ComponentMap mp) = do
  let pairs0 = Map.toAscList mp
  when (fromIntegral (length pairs0) > maxComponentPairs limits) $
    Left EncodeComponentCountExceeded

  pairs <- traverse (normalizeKeyPair limits) pairs0
  let normalizedMap = Map.fromList pairs
  when (Map.size normalizedMap /= length pairs) $
    Left EncodeKeyInvalid

  count <- lenWord32 "Component pair count" (Map.size normalizedMap)
  pairBytes <- traverse (encodePair limits) (Map.toAscList normalizedMap)

  return $ BL.toStrict $ runPut $ do
    putWord32le count
    mapM_ putByteString pairBytes

encodePair :: Limits -> (ByteString, Value) -> Either EncodeError ByteString
encodePair limits (k, v) = do
  validateKey k
  when (BS.length k > 255) $
    Left EncodeKeyLengthInvalid

  keyLen <- lenWord32 "Key length" (BS.length k)
  valueBytes <- encodeValue limits v

  return $ BL.toStrict $ runPut $ do
    putWord32le keyLen
    putByteString k
    putByteString valueBytes

encodeValue :: Limits -> Value -> Either EncodeError ByteString
encodeValue limits v =
  case v of
    VInt64 i ->
      return $ BL.toStrict $ runPut $ do
        putWord8 0x01
        putInt64le i
    VUInt64 u ->
      return $ BL.toStrict $ runPut $ do
        putWord8 0x02
        putWord64le u
    VFloat32 w -> do
      wNorm <- normalizeFloat32Bits w
      return $ BL.toStrict $ runPut $ do
        putWord8 0x03
        putWord32le wNorm
    VFloat64 w -> do
      wNorm <- normalizeFloat64Bits w
      return $ BL.toStrict $ runPut $ do
        putWord8 0x04
        putWord64le wNorm
    VString s -> do
      sNorm <- normalizeUtf8Nfc s
      when (BS.length sNorm > fromIntegral (maxStringBytes limits)) $
        Left EncodeStringTooLong
      strLen <- lenWord32 "String length" (BS.length sNorm)
      return $ BL.toStrict $ runPut $ do
        putWord8 0x05
        putWord32le strLen
        putByteString sNorm
    VBool b ->
      return $ BL.toStrict $ runPut $ do
        putWord8 0x06
        putWord8 (if b then 1 else 0)
    VNull ->
      return $ BL.toStrict $ runPut $ do
        putWord8 0x07

validateHashLength :: Snapshot -> Either EncodeError ()
validateHashLength (Snapshot _ _ (Hash h))
  | BS.length h == 32 = Right ()
  | otherwise = Left EncodeHashLength

validateHashLengthSection :: Section -> Either EncodeError ()
validateHashLengthSection (Section _ _ _ _ _ _ _ (Hash h))
  | BS.length h == 32 = Right ()
  | otherwise = Left EncodeHashLength

ensureStrictAscendingEntities :: [Entity] -> Either EncodeError ()
ensureStrictAscendingEntities [] = Right ()
ensureStrictAscendingEntities (e:es) = go (entId e) es
  where
    go _ [] = Right ()
    go prev (x:xs)
      | entId x <= prev = Left EncodeEntityIdsNotAscending
      | otherwise = go (entId x) xs

ensureEntityInRange :: Int64 -> Int64 -> Entity -> Either EncodeError ()
ensureEntityInRange minId maxId e
  | entId e < minId || entId e > maxId = Left EncodeEntityOutOfRange
  | otherwise = Right ()

normalizeUtf8Nfc :: ByteString -> Either EncodeError ByteString
normalizeUtf8Nfc bs =
  case decodeUtf8' bs of
    Left _ -> Left EncodeInvalidUtf8
    Right t -> do
      let norm = N.normalize N.NFC t
          bsNorm = encodeUtf8 norm
      if BS.isPrefixOf (BS.pack [0xEF, 0xBB, 0xBF]) bsNorm
        then Left EncodeUtf8Bom
        else Right bsNorm

validateKey :: ByteString -> Either EncodeError ()
validateKey bs
  | BS.null bs = Left EncodeKeyInvalid
  | not (isAsciiAlpha (BS.head bs) || BS.head bs == 0x5f) = Left EncodeKeyInvalid
  | BS.any (not . isAsciiIdent) bs = Left EncodeKeyInvalid
  | otherwise = Right ()
  where
    isAsciiAlpha w = (w >= 0x41 && w <= 0x5a) || (w >= 0x61 && w <= 0x7a)
    isAsciiDigit w = w >= 0x30 && w <= 0x39
    isAsciiIdent w = isAsciiAlpha w || isAsciiDigit w || w == 0x5f

normalizeFloat32Bits :: Word32 -> Either EncodeError Word32
normalizeFloat32Bits w = do
  let exponent = (w `shiftR` 23) .&. 0xff
      mantissa = w .&. 0x7fffff
  when (exponent == 0xff) $
    Left EncodeFloatNaNOrInfinity
  if exponent == 0 && mantissa == 0
    then return (w .&. 0x7fffffff)
    else return w

normalizeFloat64Bits :: Word64 -> Either EncodeError Word64
normalizeFloat64Bits w = do
  let exponent = (w `shiftR` 52) .&. 0x7ff
      mantissa = w .&. 0x000fffffffffffff
  when (exponent == 0x7ff) $
    Left EncodeFloatNaNOrInfinity
  if exponent == 0 && mantissa == 0
    then return (w .&. 0x7fffffffffffffff)
    else return w

normalizeKeyPair :: Limits -> (ByteString, Value) -> Either EncodeError (ByteString, Value)
normalizeKeyPair limits (k, v) = do
  kNorm <- normalizeUtf8Nfc k
  validateKey kNorm
  when (BS.length kNorm > 255) $
    Left EncodeKeyLengthInvalid
  when (BS.length kNorm > fromIntegral (maxStringBytes limits)) $
    Left EncodeStringTooLong
  return (kNorm, v)

lenWord32 :: String -> Int -> Either EncodeError Word32
lenWord32 label n
  | n < 0 = Left EncodeLengthOverflow
  | n > fromIntegral (maxBound :: Word32) = Left EncodeLengthOverflow
  | otherwise = Right (fromIntegral n)
