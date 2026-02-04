module Snapshot.Universe.Core
  ( decodeInstruction
  , decodeStream
  , encodeInstruction
  , encodeStream
  , hashInstruction
  , step
  , applyInstructions
  , opcodeNOP
  , opcodeAdvanceTick
  , opcodeCreateEntity
  , opcodeDeleteEntity
  , opcodeSetComponent
  , opcodeRemoveComponent
  , haltReasonToCode
  , codeToHaltReason
  ) where

import Snapshot.Types
import Snapshot.Universe.Types
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Decode (decodeSnapshot)

import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Bits ((.&.), (.|.), complement, shiftL, shiftR)
import Data.Word (Word8, Word16, Word32, Word64)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Crypto.Hash.SHA256 as SHA
import Control.Monad (when)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Normalize as N

opcodeNOP :: Opcode
opcodeNOP = Opcode 0x0001

opcodeAdvanceTick :: Opcode
opcodeAdvanceTick = Opcode 0x3001

opcodeCreateEntity :: Opcode
opcodeCreateEntity = Opcode 0x1001

opcodeDeleteEntity :: Opcode
opcodeDeleteEntity = Opcode 0x1002

opcodeSetComponent :: Opcode
opcodeSetComponent = Opcode 0x2001

opcodeRemoveComponent :: Opcode
opcodeRemoveComponent = Opcode 0x2002

decodeInstruction :: ByteString -> Either HaltReason Instruction
decodeInstruction = decodeInstructionWith defaultInstructionLimits

decodeInstructionWith :: InstructionLimits -> ByteString -> Either HaltReason Instruction
decodeInstructionWith limits bs
  | BS.length bs < 8 = Left ErrMalformedInstruction
  | fromIntegral (BS.length bs) > maxInstructionSize limits = Left ErrLimitExceeded
  | otherwise =
      case runGetOrFail parser (BL.fromStrict bs) of
        Left _ -> Left ErrMalformedInstruction
        Right (remaining, _, instr) ->
          if BL.null remaining
            then Right instr
            else Left ErrMalformedInstruction
  where
    parser = do
      op <- getWord16le
      flags <- getWord16le
      whenFlagNonZero flags
      len <- getWord32le
      whenPayloadTooLarge limits len
      let totalLen = 8 + fromIntegral len
      when (fromIntegral totalLen /= BS.length bs) $
        fail "length mismatch"
      payload <- getByteString (fromIntegral len)
      return (Instruction (Opcode op) flags payload)

decodeStream :: ByteString -> Either HaltReason [Instruction]
decodeStream = decodeStreamWith defaultInstructionLimits

decodeStreamWith :: InstructionLimits -> ByteString -> Either HaltReason [Instruction]
decodeStreamWith limits bs = do
  (count, rest0) <- takeWord32 bs
  if count > maxInstructionsPerStream limits
    then Left ErrLimitExceeded
    else go count rest0 []
  where
    go 0 rest acc =
      if BS.null rest
        then Right (reverse acc)
        else Left ErrMalformedInstruction
    go n rest acc = do
      (ilen, rest1) <- takeWord32 rest
      if ilen > maxInstructionSize limits
        then Left ErrLimitExceeded
        else do
          (ibytes, rest2) <- takeBytes ilen rest1
          instr <- decodeInstructionWith limits ibytes
          go (n - 1) rest2 (instr : acc)

encodeInstruction :: Instruction -> Either HaltReason ByteString
encodeInstruction instr
  | instrFlags instr /= 0 = Left ErrMalformedInstruction
  | fromIntegral (BS.length (instrPayload instr)) > maxPayloadSize defaultInstructionLimits = Left ErrLimitExceeded
  | otherwise =
      let payload = instrPayload instr
          len = fromIntegral (BS.length payload) :: Word32
      in Right $ BL.toStrict $ runPut $ do
           putWord16le (opcodeWord (instrOpcode instr))
           putWord16le (instrFlags instr)
           putWord32le len
           putByteString payload

encodeStream :: [Instruction] -> Either HaltReason ByteString
encodeStream = encodeStreamWith defaultInstructionLimits

encodeStreamWith :: InstructionLimits -> [Instruction] -> Either HaltReason ByteString
encodeStreamWith limits instrs
  | fromIntegral (length instrs) > maxInstructionsPerStream limits = Left ErrLimitExceeded
  | otherwise = do
      encoded <- traverse encodeInstruction instrs
      let payloads = map BS.length encoded
      if any (\n -> fromIntegral n > maxInstructionSize limits) payloads
        then Left ErrLimitExceeded
        else Right $ BL.toStrict $ runPut $ do
          putWord32le (fromIntegral (length encoded))
          mapM_ putOne encoded
  where
    putOne bytes = do
      putWord32le (fromIntegral (BS.length bytes))
      putByteString bytes

hashInstruction :: Instruction -> Either HaltReason ByteString
hashInstruction instr = do
  bytes <- encodeInstruction instr
  return (SHA.hash bytes)

haltReasonToCode :: HaltReason -> Word16
haltReasonToCode r =
  case r of
    ErrUnknownOpcode -> 0x0001
    ErrUnauthorized -> 0x0002
    ErrEntityExists -> 0x0003
    ErrEntityMissing -> 0x0004
    ErrInvalidKey -> 0x0005
    ErrInvalidValue -> 0x0006
    ErrInvalidType -> 0x0007
    ErrInvalidTick -> 0x0008
    ErrCanonicalViolation -> 0x0009
    ErrLimitExceeded -> 0x000A
    ErrInternalInvariant -> 0x000B
    ErrMalformedInstruction -> 0x000C

codeToHaltReason :: Word16 -> Maybe HaltReason
codeToHaltReason w =
  case w of
    0x0001 -> Just ErrUnknownOpcode
    0x0002 -> Just ErrUnauthorized
    0x0003 -> Just ErrEntityExists
    0x0004 -> Just ErrEntityMissing
    0x0005 -> Just ErrInvalidKey
    0x0006 -> Just ErrInvalidValue
    0x0007 -> Just ErrInvalidType
    0x0008 -> Just ErrInvalidTick
    0x0009 -> Just ErrCanonicalViolation
    0x000A -> Just ErrLimitExceeded
    0x000B -> Just ErrInternalInvariant
    0x000C -> Just ErrMalformedInstruction
    _ -> Nothing

step :: Snapshot -> AuthorityMask -> Instruction -> (Result, Snapshot)
step snap auth instr =
  if (maskOf auth .&. complement allowedMask) /= 0
    then (Halt ErrInternalInvariant, snap)
    else case instrOpcode instr of
    op | op == opcodeNOP -> (Next, snap)
    op | op == opcodeAdvanceTick ->
      case decodeAdvanceTick (instrPayload instr) of
        Left reason -> (Halt reason, snap)
        Right delta ->
          if not (hasAuth auth bitAdmin)
            then (Halt ErrUnauthorized, snap)
            else
              let t0 = snapTick snap
                  t1 = t0 + delta
              in if delta == 0 || t1 < t0
                   then (Halt ErrInvalidTick, snap)
                   else (Next, snap { snapTick = t1 })
    op | op == opcodeCreateEntity ->
      case decodeCreateEntity (instrPayload instr) of
        Left reason -> (Halt reason, snap)
        Right (eid, etype, ownerMask) ->
          if not (hasAuth auth bitCreate)
            then (Halt ErrUnauthorized, snap)
            else applyMutation snap (insertEntity eid etype ownerMask)
    op | op == opcodeDeleteEntity ->
      case decodeDeleteEntity (instrPayload instr) of
        Left reason -> (Halt reason, snap)
        Right eid ->
          case lookupEntity snap eid of
            Nothing -> (Halt ErrEntityMissing, snap)
            Just ent ->
              if not (hasAuth auth bitDelete)
                then (Halt ErrUnauthorized, snap)
                else case ownerAllows auth ent of
                  Left err -> (Halt err, snap)
                  Right ok ->
                    if not ok
                      then (Halt ErrUnauthorized, snap)
                      else applyMutation snap (deleteEntity eid)
    op | op == opcodeSetComponent ->
      case decodeSetComponent (instrPayload instr) of
        Left reason -> (Halt reason, snap)
        Right (eid, key, val) ->
          case lookupEntity snap eid of
            Nothing -> (Halt ErrEntityMissing, snap)
            Just ent ->
              if not (hasAuth auth bitWrite)
                then (Halt ErrUnauthorized, snap)
                else if isOwnerKey key && not (hasAuth auth bitAdmin)
                  then (Halt ErrUnauthorized, snap)
                  else case ownerAllows auth ent of
                    Left err -> (Halt err, snap)
                    Right ok ->
                      if not ok
                        then (Halt ErrUnauthorized, snap)
                        else applyMutation snap (setComponent eid key val)
    op | op == opcodeRemoveComponent ->
      case decodeRemoveComponent (instrPayload instr) of
        Left reason -> (Halt reason, snap)
        Right (eid, key) ->
          case lookupEntity snap eid of
            Nothing -> (Halt ErrEntityMissing, snap)
            Just ent ->
              if not (hasAuth auth bitWrite)
                then (Halt ErrUnauthorized, snap)
                else if isOwnerKey key && not (hasAuth auth bitAdmin)
                  then (Halt ErrUnauthorized, snap)
                  else case ownerAllows auth ent of
                    Left err -> (Halt err, snap)
                    Right ok ->
                      if not ok
                        then (Halt ErrUnauthorized, snap)
                        else applyMutation snap (removeComponent eid key)
    _ -> (Halt ErrUnknownOpcode, snap)

applyInstructions :: Snapshot -> AuthorityMask -> [Instruction] -> (Result, Snapshot)
applyInstructions snap _auth [] = (Next, snap)
applyInstructions snap auth (i:is) =
  case step snap auth i of
    (Next, snap') -> applyInstructions snap' auth is
    (Halt r, snap') -> (Halt r, snap')

decodeAdvanceTick :: ByteString -> Either HaltReason Word64
decodeAdvanceTick payload
  | BS.length payload /= 8 = Left ErrInvalidTick
  | otherwise =
      case runGetOrFail getWord64le (BL.fromStrict payload) of
        Left _ -> Left ErrInvalidTick
        Right (_, _, v) -> Right v

decodeCreateEntity :: ByteString -> Either HaltReason (Int64, ByteString, Word64)
decodeCreateEntity payload =
  case runGetOrFail parser (BL.fromStrict payload) of
    Left _ -> Left ErrMalformedInstruction
    Right (remaining, _, (eid, ty, ownerMask)) ->
      if BL.null remaining then Right (eid, ty, ownerMask) else Left ErrMalformedInstruction
  where
    parser = do
      eid <- getInt64le
      len <- getWord32le
      ty <- getByteString (fromIntegral len)
      ownerMask <- getWord64le
      return (eid, ty, ownerMask)

decodeDeleteEntity :: ByteString -> Either HaltReason Int64
decodeDeleteEntity payload
  | BS.length payload /= 8 = Left ErrMalformedInstruction
  | otherwise =
      case runGetOrFail getInt64le (BL.fromStrict payload) of
        Left _ -> Left ErrMalformedInstruction
        Right (_, _, eid) -> Right eid

decodeSetComponent :: ByteString -> Either HaltReason (Int64, ByteString, Value)
decodeSetComponent payload =
  case runGetOrFail parser (BL.fromStrict payload) of
    Left _ -> Left ErrMalformedInstruction
    Right (_, _, Left err) -> Left err
    Right (remaining, _, Right res) ->
      if BL.null remaining then Right res else Left ErrMalformedInstruction
  where
    parser = do
      eid <- getInt64le
      klen <- getWord32le
      if klen == 0 || klen > 255
        then return (Left ErrInvalidKey)
        else do
          key <- getByteString (fromIntegral klen)
          if not (validateKeyAscii key)
            then return (Left ErrInvalidKey)
            else do
              vtype <- getWord8
              vres <- getValueE vtype
              return (fmap (\v -> (eid, key, v)) vres)

decodeRemoveComponent :: ByteString -> Either HaltReason (Int64, ByteString)
decodeRemoveComponent payload =
  case runGetOrFail parser (BL.fromStrict payload) of
    Left _ -> Left ErrMalformedInstruction
    Right (_, _, Left err) -> Left err
    Right (remaining, _, Right res) ->
      if BL.null remaining then Right res else Left ErrMalformedInstruction
  where
    parser = do
      eid <- getInt64le
      klen <- getWord32le
      if klen == 0 || klen > 255
        then return (Left ErrInvalidKey)
        else do
          key <- getByteString (fromIntegral klen)
          if not (validateKeyAscii key)
            then return (Left ErrInvalidKey)
            else return (Right (eid, key))

getValueE :: Word8 -> Get (Either HaltReason Value)
getValueE t =
  case t of
    0x01 -> Right . VInt64 <$> getInt64le
    0x02 -> Right . VUInt64 <$> getWord64le
    0x03 -> Right . VFloat32 <$> getWord32le
    0x04 -> Right . VFloat64 <$> getWord64le
    0x05 -> do
      len <- getWord32le
      bytes <- getByteString (fromIntegral len)
      return (Right (VString bytes))
    0x06 -> do
      b <- getWord8
      case b of
        0 -> return (Right (VBool False))
        1 -> return (Right (VBool True))
        _ -> return (Left ErrInvalidValue)
    0x07 -> return (Right VNull)
    _ -> return (Left ErrInvalidValue)

takeWord32 :: ByteString -> Either HaltReason (Word32, ByteString)
takeWord32 bs =
  case runGetOrFail getWord32le (BL.fromStrict bs) of
    Left _ -> Left ErrMalformedInstruction
    Right (remaining, _, v) -> Right (v, BL.toStrict remaining)

takeBytes :: Word32 -> ByteString -> Either HaltReason (ByteString, ByteString)
takeBytes n bs
  | fromIntegral n > BS.length bs = Left ErrMalformedInstruction
  | otherwise = Right (BS.take (fromIntegral n) bs, BS.drop (fromIntegral n) bs)

whenFlagNonZero :: Word16 -> Get ()
whenFlagNonZero flags =
  when (flags /= 0) (fail "flags must be zero")

whenPayloadTooLarge :: InstructionLimits -> Word32 -> Get ()
whenPayloadTooLarge limits len =
  when (len > maxPayloadSize limits) (fail "payload too large")

opcodeWord :: Opcode -> Word16
opcodeWord (Opcode w) = w

bitCreate, bitDelete, bitWrite, bitAdmin :: Word64
bitCreate = 1 `shiftL` 0
bitDelete = 1 `shiftL` 1
bitWrite = 1 `shiftL` 2
bitAdmin = 1 `shiftL` 3

allowedMask :: Word64
allowedMask = bitCreate .|. bitDelete .|. bitWrite .|. bitAdmin

hasAuth :: AuthorityMask -> Word64 -> Bool
hasAuth (AuthorityMask m) bit = (m .&. bit) /= 0

isOwnerKey :: ByteString -> Bool
isOwnerKey k = k == BS.pack [0x5f,0x6f,0x77,0x6e,0x65,0x72] -- "_owner"

ownerAllows :: AuthorityMask -> Entity -> Either HaltReason Bool
ownerAllows auth ent =
  case lookupOwner ent of
    Left err -> Left err
    Right Nothing -> Right (hasAuth auth bitAdmin)
    Right (Just mask) -> Right ((mask .&. maskOf auth) /= 0)

maskOf :: AuthorityMask -> Word64
maskOf (AuthorityMask m) = m

lookupOwner :: Entity -> Either HaltReason (Maybe Word64)
lookupOwner (Entity _ _ (ComponentMap mp)) =
  case Map.lookup (BS.pack [0x5f,0x6f,0x77,0x6e,0x65,0x72]) mp of
    Just (VUInt64 w) -> Right (Just w)
    Just _ -> Left ErrInternalInvariant
    Nothing -> Right Nothing

lookupEntity :: Snapshot -> Int64 -> Maybe Entity
lookupEntity snap eid = go (snapEntities snap)
  where
    go [] = Nothing
    go (e:es)
      | entId e == eid = Just e
      | entId e > eid = Nothing
      | otherwise = go es

insertEntity :: Int64 -> ByteString -> Word64 -> Snapshot -> Either HaltReason Snapshot
insertEntity eid etype ownerMask snap =
  case validateEntityType etype of
    Left err -> Left err
    Right () ->
      if (ownerMask .&. complement allowedMask) /= 0
        then Left ErrInvalidValue
        else case lookupEntity snap eid of
          Just _ -> Left ErrEntityExists
          Nothing ->
            let ownerKey = BS.pack [0x5f,0x6f,0x77,0x6e,0x65,0x72]
                comp = ComponentMap (Map.fromList [(ownerKey, VUInt64 ownerMask)])
                ent = Entity eid etype comp
                ents = insertOrdered ent (snapEntities snap)
            in Right (snap { snapEntities = ents })

deleteEntity :: Int64 -> Snapshot -> Either HaltReason Snapshot
deleteEntity eid snap =
  case lookupEntity snap eid of
    Nothing -> Left ErrEntityMissing
    Just _ ->
      let ents = filter (\e -> entId e /= eid) (snapEntities snap)
      in Right (snap { snapEntities = ents })

setComponent :: Int64 -> ByteString -> Value -> Snapshot -> Either HaltReason Snapshot
setComponent eid key val snap =
  case validateKeyAscii key of
    False -> Left ErrInvalidKey
    True ->
      case validateValue val of
        Left err -> Left err
        Right () ->
          case lookupEntity snap eid of
            Nothing -> Left ErrEntityMissing
            Just ent ->
              let Entity _ ty (ComponentMap mp) = ent
                  mp' = Map.insert key val mp
                  ent' = Entity eid ty (ComponentMap mp')
                  ents = replaceEntity ent' (snapEntities snap)
              in Right (snap { snapEntities = ents })

removeComponent :: Int64 -> ByteString -> Snapshot -> Either HaltReason Snapshot
removeComponent eid key snap =
  if not (validateKeyAscii key)
    then Left ErrInvalidKey
    else case lookupEntity snap eid of
      Nothing -> Left ErrEntityMissing
      Just ent ->
        let Entity _ ty (ComponentMap mp) = ent
            mp' = Map.delete key mp
            ent' = Entity eid ty (ComponentMap mp')
            ents = replaceEntity ent' (snapEntities snap)
        in Right (snap { snapEntities = ents })

replaceEntity :: Entity -> [Entity] -> [Entity]
replaceEntity e = map (\x -> if entId x == entId e then e else x)

insertOrdered :: Entity -> [Entity] -> [Entity]
insertOrdered e [] = [e]
insertOrdered e (x:xs)
  | entId e < entId x = e : x : xs
  | otherwise = x : insertOrdered e xs

applyMutation :: Snapshot -> (Snapshot -> Either HaltReason Snapshot) -> (Result, Snapshot)
applyMutation snap f =
  case f snap of
    Left err -> (Halt err, snap)
    Right snap' ->
      case encodeSnapshot snap' of
        Left _ -> (Halt ErrCanonicalViolation, snap)
        Right bytes ->
          case decodeSnapshot bytes of
            Left _ -> (Halt ErrCanonicalViolation, snap)
            Right canonical -> (Next, canonical)
validateKeyAscii :: ByteString -> Bool
validateKeyAscii bs
  | BS.null bs = False
  | not (isAlpha (BS.head bs) || BS.head bs == 0x5f) = False
  | BS.any (not . isIdent) bs = False
  | otherwise = True
  where
    isAlpha w = (w >= 0x41 && w <= 0x5a) || (w >= 0x61 && w <= 0x7a)
    isDigit w = w >= 0x30 && w <= 0x39
    isIdent w = isAlpha w || isDigit w || w == 0x5f

validateEntityType :: ByteString -> Either HaltReason ()
validateEntityType bs =
  case TE.decodeUtf8' bs of
    Left _ -> Left ErrInvalidType
    Right t ->
      let norm = N.normalize N.NFC t
          bsNorm = TE.encodeUtf8 norm
      in if bsNorm /= bs
           then Left ErrInvalidType
           else Right ()

validateValue :: Value -> Either HaltReason ()
validateValue v =
  case v of
    VString s ->
      case TE.decodeUtf8' s of
        Left _ -> Left ErrInvalidValue
        Right t ->
          let norm = N.normalize N.NFC t
              bsNorm = TE.encodeUtf8 norm
          in if bsNorm /= s
               then Left ErrInvalidValue
               else Right ()
    VFloat32 w ->
      if float32Invalid w then Left ErrInvalidValue else Right ()
    VFloat64 w ->
      if float64Invalid w then Left ErrInvalidValue else Right ()
    _ -> Right ()

float32Invalid :: Word32 -> Bool
float32Invalid w =
  let sign = w `shiftR` 31
      exponent = (w `shiftR` 23) .&. 0xff
      mantissa = w .&. 0x7fffff
  in exponent == 0xff || (exponent == 0 && mantissa == 0 && sign == 1)

float64Invalid :: Word64 -> Bool
float64Invalid w =
  let sign = w `shiftR` 63
      exponent = (w `shiftR` 52) .&. 0x7ff
      mantissa = w .&. 0x000fffffffffffff
  in exponent == 0x7ff || (exponent == 0 && mantissa == 0 && sign == 1)
