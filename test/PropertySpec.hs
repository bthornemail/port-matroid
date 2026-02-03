module Main (main) where

import Snapshot.Decode (decodeSnapshot, decodeSection)
import Snapshot.Encode (encodeSnapshot, encodeSection, encodeSnapshotWith)
import Snapshot.Errors (DecodeError, EncodeError(..))
import Snapshot.Limits (Limits(..), defaultLimits)
import Snapshot.Types

import Control.Exception (evaluate, try, SomeException)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Normalize as N
import Data.List (sortOn)
import Data.Word (Word64)
import Data.Int (Int64)
import System.IO (hFlush, stdout)
import Test.QuickCheck

main :: IO ()
main = do
  _ <- evaluate (T.length (N.normalize N.NFC (T.pack "warmup")))
  let args = stdArgs { maxSuccess = 50, maxSize = 15 }
  runQC args "snapshot_idempotent" prop_snapshot_idempotent
  runQC args "snapshot_hash" prop_snapshot_hash
  runQC args "section_idempotent" prop_section_idempotent
  runQC args "section_hash" prop_section_hash
  runQC args "decoder_totality" prop_decoder_totality
  runQC args "decoder_section_totality" prop_decoder_section_totality
  runQC args "encode_decode_roundtrip" prop_encode_decode_roundtrip
  runQC args "hash_law_generated" prop_hash_law_generated
  runQC args "entity_permutation_invariant" prop_entity_permutation_invariant
  runQC args "nfc_type_equivalence" prop_nfc_type_equivalence
  runQC args "negative_zero_component" prop_negative_zero_component
  runQC args "duplicate_entity_rejected" prop_duplicate_entity_rejected
  runQC args "decoder_truncated_totality" prop_decoder_truncated_totality
  runQC args "canonicalization_projection" prop_canonicalization_projection
  runQC args "key_length_max" prop_key_length_max
  runQC args "key_length_over" prop_key_length_over
  runQC args "string_length_limit" prop_string_length_limit
  runQC args "string_length_over" prop_string_length_over
  runQC args "entity_count_limit" prop_entity_count_limit
  runQC args "entity_count_over" prop_entity_count_over
  runQC args "component_count_limit" prop_component_count_limit
  runQC args "component_count_over" prop_component_count_over
  runQC args "zero_length_string" prop_zero_length_string
  runQC args "zero_components" prop_zero_components
  runQC args "entity_id_edges" prop_entity_id_edges

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  hFlush stdout
  quickCheckWith args prop

fixedSnapshot :: Snapshot
fixedSnapshot =
  let ent = Entity 1 (BSC.pack "test") (ComponentMap (Map.fromList [(BSC.pack "name", VString (BSC.pack "test"))]))
      h = Hash (BS.replicate 32 0)
  in Snapshot 0 [ent] h

fixedSection :: Section
fixedSection =
  let ent = Entity 1 (BSC.pack "test") (ComponentMap (Map.fromList [(BSC.pack "name", VString (BSC.pack "test"))]))
      h = Hash (BS.replicate 32 0)
  in Section 0 0 1 1 1 0 [ent] h

prop_snapshot_idempotent :: Property
prop_snapshot_idempotent =
  forAll (pure fixedSnapshot) $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        case decodeSnapshot bytes of
          Left err -> counterexample ("decode failed: " ++ show err) False
          Right snap2 ->
            case encodeSnapshot snap2 of
              Left err -> counterexample ("re-encode failed: " ++ show err) False
              Right bytes2 -> bytes2 === bytes

prop_snapshot_hash :: Property
prop_snapshot_hash =
  forAll (pure fixedSnapshot) $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        let preimage = BS.take (BS.length bytes - 32) bytes
            expected = SHA.hash preimage
            actual = BS.drop (BS.length bytes - 32) bytes
        in actual === expected

prop_section_idempotent :: Property
prop_section_idempotent =
  forAll (pure fixedSection) $ \sec ->
    case encodeSection sec of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        case decodeSection bytes of
          Left err -> counterexample ("decode failed: " ++ show err) False
          Right sec2 ->
            case encodeSection sec2 of
              Left err -> counterexample ("re-encode failed: " ++ show err) False
              Right bytes2 -> bytes2 === bytes

prop_section_hash :: Property
prop_section_hash =
  forAll (pure fixedSection) $ \sec ->
    case encodeSection sec of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        let preimage = BS.take (BS.length bytes - 32) bytes
            expected = SHA.hash preimage
            actual = BS.drop (BS.length bytes - 32) bytes
        in actual === expected

prop_decoder_totality :: Property
prop_decoder_totality =
  forAll genBytes $ \bs -> ioProperty $ do
    result <- try (evaluate (decodeSnapshot bs)) :: IO (Either SomeException (Either DecodeError Snapshot))
    case result of
      Left _ -> pure False
      Right _ -> pure True

prop_decoder_section_totality :: Property
prop_decoder_section_totality =
  forAll genBytes $ \bs -> ioProperty $ do
    result <- try (evaluate (decodeSection bs)) :: IO (Either SomeException (Either DecodeError Section))
    case result of
      Left _ -> pure False
      Right _ -> pure True

prop_encode_decode_roundtrip :: Property
prop_encode_decode_roundtrip =
  forAll genSnapshot $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        case decodeSnapshot bytes of
          Left err -> counterexample ("decode failed: " ++ show err) False
          Right snap2 -> snap2 === snap

prop_hash_law_generated :: Property
prop_hash_law_generated =
  forAll genSnapshot $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        let preimage = BS.take (BS.length bytes - 32) bytes
            expected = SHA.hash preimage
            actual = BS.drop (BS.length bytes - 32) bytes
        in actual === expected

prop_entity_permutation_invariant :: Property
prop_entity_permutation_invariant =
  forAll genSnapshot $ \snap ->
    forAll (shuffle (snapEntities snap)) $ \shuffled ->
      let s1 = snap { snapEntities = shuffled }
          s2 = snap { snapEntities = sortOn entId (snapEntities snap) }
      in encodeSnapshot s1 === encodeSnapshot s2

prop_nfc_type_equivalence :: Property
prop_nfc_type_equivalence =
  let decomposed = T.pack "e\x0301"
      composed = N.normalize N.NFC decomposed
      s1 = mkSnapshotWithType decomposed
      s2 = mkSnapshotWithType composed
  in encodeSnapshot s1 === encodeSnapshot s2

prop_negative_zero_component :: Property
prop_negative_zero_component =
  let negZero = 0x8000000000000000
      posZero = 0x0000000000000000
  in encodeSnapshot (mkFloatSnapshot negZero) === encodeSnapshot (mkFloatSnapshot posZero)

prop_duplicate_entity_rejected :: Property
prop_duplicate_entity_rejected =
  let entA = Entity 1 (BSC.pack "a") (ComponentMap Map.empty)
      entB = Entity 1 (BSC.pack "b") (ComponentMap Map.empty)
      snap = Snapshot 0 [entA, entB] (Hash (BS.replicate 32 0))
  in encodeSnapshot snap === Left EncodeEntityIdsNotAscending

prop_decoder_truncated_totality :: Property
prop_decoder_truncated_totality =
  forAll genSnapshot $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        forAll (chooseInt (0, max 0 (BS.length bytes - 1))) $ \k ->
          ioProperty $ do
            let truncated = BS.take k bytes
            result <- try (evaluate (decodeSnapshot truncated)) :: IO (Either SomeException (Either DecodeError Snapshot))
            case result of
              Left _ -> pure False
              Right (Left _) -> pure True
              Right (Right _) -> pure False

prop_canonicalization_projection :: Property
prop_canonicalization_projection =
  forAll genDirtySnapshot $ \(dirty, canon) ->
    encodeSnapshot dirty === encodeSnapshot canon

prop_key_length_max :: Property
prop_key_length_max =
  let lim = defaultLimits { maxStringBytes = 300, maxComponentPairs = 1, maxEntities = 1, maxSnapshotBytes = 4096 }
      key = BS.cons 0x61 (BS.replicate 254 0x62)
      snap = mkSnapshotWithComponents [(key, VInt64 1)]
  in case encodeSnapshotWith lim snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_key_length_over :: Property
prop_key_length_over =
  let lim = defaultLimits { maxStringBytes = 300, maxComponentPairs = 1, maxEntities = 1, maxSnapshotBytes = 4096 }
      key = BS.cons 0x61 (BS.replicate 255 0x62)
      snap = mkSnapshotWithComponents [(key, VInt64 1)]
  in encodeSnapshotWith lim snap === Left EncodeKeyLengthInvalid

prop_string_length_limit :: Property
prop_string_length_limit =
  let lim = defaultLimits { maxStringBytes = 8, maxComponentPairs = 1, maxEntities = 1, maxSnapshotBytes = 4096 }
      val = VString (BS.replicate 8 0x61)
      snap = mkSnapshotWithComponents [(BSC.pack "k", val)]
  in case encodeSnapshotWith lim snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_string_length_over :: Property
prop_string_length_over =
  let lim = defaultLimits { maxStringBytes = 8, maxComponentPairs = 1, maxEntities = 1, maxSnapshotBytes = 4096 }
      val = VString (BS.replicate 9 0x61)
      snap = mkSnapshotWithComponents [(BSC.pack "k", val)]
  in encodeSnapshotWith lim snap === Left EncodeStringTooLong

prop_entity_count_limit :: Property
prop_entity_count_limit =
  let lim = defaultLimits { maxEntities = 2, maxComponentPairs = 0, maxSnapshotBytes = 4096 }
      snap = Snapshot 0 [mkEntity 1, mkEntity 2] (Hash (BS.replicate 32 0))
  in case encodeSnapshotWith lim snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_entity_count_over :: Property
prop_entity_count_over =
  let lim = defaultLimits { maxEntities = 2, maxComponentPairs = 0, maxSnapshotBytes = 4096 }
      snap = Snapshot 0 [mkEntity 1, mkEntity 2, mkEntity 3] (Hash (BS.replicate 32 0))
  in encodeSnapshotWith lim snap === Left EncodeEntityCountExceeded

prop_component_count_limit :: Property
prop_component_count_limit =
  let lim = defaultLimits { maxComponentPairs = 2, maxEntities = 1, maxSnapshotBytes = 4096 }
      snap = mkSnapshotWithComponents [(BSC.pack "a", VInt64 1), (BSC.pack "b", VInt64 2)]
  in case encodeSnapshotWith lim snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_component_count_over :: Property
prop_component_count_over =
  let lim = defaultLimits { maxComponentPairs = 2, maxEntities = 1, maxSnapshotBytes = 4096 }
      snap = mkSnapshotWithComponents [(BSC.pack "a", VInt64 1), (BSC.pack "b", VInt64 2), (BSC.pack "c", VInt64 3)]
  in encodeSnapshotWith lim snap === Left EncodeComponentCountExceeded

prop_zero_length_string :: Property
prop_zero_length_string =
  let snap = mkSnapshotWithComponents [(BSC.pack "k", VString BS.empty)]
  in case encodeSnapshot snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_zero_components :: Property
prop_zero_components =
  let ent = Entity 1 (BSC.pack "t") (ComponentMap Map.empty)
      snap = Snapshot 0 [ent] (Hash (BS.replicate 32 0))
  in case encodeSnapshot snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

prop_entity_id_edges :: Property
prop_entity_id_edges =
  let minId = minBound :: Int64
      maxId = maxBound :: Int64
      snap = Snapshot 0 [mkEntity minId, mkEntity maxId] (Hash (BS.replicate 32 0))
  in case encodeSnapshot snap of
       Right _ -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False

genBytes :: Gen BS.ByteString
genBytes = BS.pack <$> listOf arbitrary

genSnapshot :: Gen Snapshot
genSnapshot = do
  n <- chooseInt (0, 4)
  ents <- mapM genEntity [1..n]
  pure (Snapshot 0 ents (Hash (BS.replicate 32 0)))

genEntity :: Int -> Gen Entity
genEntity i = do
  t <- genAsciiText
  comp <- genComponentMap
  pure (Entity (fromIntegral i) (TE.encodeUtf8 t) comp)

genComponentMap :: Gen ComponentMap
genComponentMap = do
  let keys = ["a", "b", "c", "d"]
  ks <- sublistOf keys
  pairs <- mapM genPair ks
  pure (ComponentMap (Map.fromList pairs))

genPair :: String -> Gen (BS.ByteString, Value)
genPair k = do
  v <- genValue
  pure (TE.encodeUtf8 (T.pack k), v)

genValue :: Gen Value
genValue =
  oneof
    [ VInt64 . fromIntegral <$> (chooseInt (-1000, 1000) :: Gen Int)
    , VUInt64 . fromIntegral <$> (chooseInt (0, 1000) :: Gen Int)
    , VBool <$> arbitrary
    , pure VNull
    , VString . TE.encodeUtf8 <$> genAsciiText
    ]

genAsciiText :: Gen T.Text
genAsciiText = T.pack <$> listOf (elements ascii)
  where
    ascii = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ [' ', '-', '_']

mkSnapshotWithType :: T.Text -> Snapshot
mkSnapshotWithType txt =
  Snapshot 0 [Entity 1 (TE.encodeUtf8 txt) (ComponentMap Map.empty)] (Hash (BS.replicate 32 0))

mkFloatSnapshot :: Word64 -> Snapshot
mkFloatSnapshot bits =
  let key = TE.encodeUtf8 (T.pack "f")
      comp = ComponentMap (Map.fromList [(key, VFloat64 bits)])
      ent = Entity 1 (BSC.pack "type") comp
  in Snapshot 0 [ent] (Hash (BS.replicate 32 0))

mkEntity :: Int64 -> Entity
mkEntity eid = Entity eid (BSC.pack "t") (ComponentMap Map.empty)

mkSnapshotWithComponents :: [(BS.ByteString, Value)] -> Snapshot
mkSnapshotWithComponents pairs =
  let comp = ComponentMap (Map.fromList pairs)
      ent = Entity 1 (BSC.pack "t") comp
  in Snapshot 0 [ent] (Hash (BS.replicate 32 0))

genDirtySnapshot :: Gen (Snapshot, Snapshot)
genDirtySnapshot = do
  n <- chooseInt (0, 4)
  ents <- mapM genDirtyEntity [1..n]
  shuffled <- shuffle (map fst ents)
  let canonEnts = map snd ents
      canonSorted = sortOn entId canonEnts
      dirtySnap = Snapshot 0 shuffled (Hash (BS.replicate 32 7))
      canonSnap = Snapshot 0 canonSorted (Hash (BS.replicate 32 7))
  pure (dirtySnap, canonSnap)

genDirtyEntity :: Int -> Gen (Entity, Entity)
genDirtyEntity i = do
  (tDirty, tCanon) <- genDirtyText
  (compDirty, compCanon) <- genDirtyComponentMap
  let entDirty = Entity (fromIntegral i) (TE.encodeUtf8 tDirty) compDirty
      entCanon = Entity (fromIntegral i) (TE.encodeUtf8 tCanon) compCanon
  pure (entDirty, entCanon)

genDirtyComponentMap :: Gen (ComponentMap, ComponentMap)
genDirtyComponentMap = do
  let keys = ["a", "b", "c", "d"]
  ks <- sublistOf keys
  pairs <- mapM genDirtyPair ks
  let dirtyPairs = map (\(k, v, _) -> (k, v)) pairs
      canonPairs = map (\(k, _, v) -> (k, v)) pairs
  pure (ComponentMap (Map.fromList dirtyPairs), ComponentMap (Map.fromList canonPairs))

genDirtyPair :: String -> Gen (BS.ByteString, Value, Value)
genDirtyPair k = do
  (vDirty, vCanon) <- genDirtyValue
  pure (TE.encodeUtf8 (T.pack k), vDirty, vCanon)

genDirtyValue :: Gen (Value, Value)
genDirtyValue =
  oneof
    [ do
        (tDirty, tCanon) <- genDirtyText
        let bDirty = TE.encodeUtf8 tDirty
            bCanon = TE.encodeUtf8 tCanon
        pure (VString bDirty, VString bCanon)
    , do
        bits <- elements [0x8000000000000000, 0x0000000000000000, 0x3ff0000000000000]
        let canon = if bits == 0x8000000000000000 then 0x0000000000000000 else bits
        pure (VFloat64 bits, VFloat64 canon)
    , do
        bits <- elements [0x80000000, 0x00000000, 0x3f800000]
        let canon = if bits == 0x80000000 then 0x00000000 else bits
        pure (VFloat32 bits, VFloat32 canon)
    , do
        v <- VInt64 . fromIntegral <$> (chooseInt (-1000, 1000) :: Gen Int)
        pure (v, v)
    , do
        v <- VUInt64 . fromIntegral <$> (chooseInt (0, 1000) :: Gen Int)
        pure (v, v)
    , do
        v <- VBool <$> arbitrary
        pure (v, v)
    , pure (VNull, VNull)
    ]

genDirtyText :: Gen (T.Text, T.Text)
genDirtyText =
  frequency
    [ (3, do
        t <- genAsciiText
        let canon = N.normalize N.NFC t
        pure (t, canon))
    , (1, do
        let dirty = T.pack "e\x0301"
            canon = N.normalize N.NFC dirty
        pure (dirty, canon))
    ]
