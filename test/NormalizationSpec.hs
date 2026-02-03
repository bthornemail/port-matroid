{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Errors (EncodeError(..))
import Snapshot.Types

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Normalize as N
import Data.Word (Word64)
import Test.QuickCheck

main :: IO ()
main = do
  let args = stdArgs { maxSuccess = 200, maxSize = 20 }
  runQC args "nfc_idempotent" prop_nfc_idempotent
  runQC args "negative_zero_canonical" prop_negative_zero_canonical
  runQC args "roundtrip_stable" prop_roundtrip_stable
  runQC args "encoder_rejects_nan" prop_encoder_rejects_nan

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  quickCheckWith args prop

zeroHash :: Hash
zeroHash = Hash (BS.replicate 32 0)

mkSnapshotWithType :: T.Text -> Snapshot
mkSnapshotWithType txt =
  Snapshot 0 [Entity 1 (TE.encodeUtf8 txt) (ComponentMap Map.empty)] zeroHash

mkFloatSnapshot :: Word64 -> Snapshot
mkFloatSnapshot bits =
  let key = TE.encodeUtf8 "f"
      comp = ComponentMap (Map.fromList [(key, VFloat64 bits)])
      ent = Entity 1 (TE.encodeUtf8 "type") comp
  in Snapshot 0 [ent] zeroHash

-- Property 1: Encoder NFC idempotency
prop_nfc_idempotent :: Property
prop_nfc_idempotent =
  forAll genText $ \txt ->
    let nfc = N.normalize N.NFC txt
        s1 = mkSnapshotWithType txt
        s2 = mkSnapshotWithType nfc
    in classify (txt /= nfc) "non-NFC input" $
         encodeSnapshot s1 === encodeSnapshot s2

-- Property 2: -0.0 canonicalization
prop_negative_zero_canonical :: Property
prop_negative_zero_canonical =
  let negZero = 0x8000000000000000
      posZero = 0x0000000000000000
  in encodeSnapshot (mkFloatSnapshot negZero) === encodeSnapshot (mkFloatSnapshot posZero)

-- Property 3: encode ∘ decode stability
prop_roundtrip_stable :: Property
prop_roundtrip_stable =
  forAll genSnapshot $ \snap ->
    case encodeSnapshot snap of
      Left err -> counterexample ("encode failed: " ++ show err) False
      Right bytes ->
        case decodeSnapshot bytes of
          Left err -> counterexample ("decode failed: " ++ show err) False
          Right snap2 ->
            encodeSnapshot snap2 === Right bytes

-- Property 4: encoder rejects NaN payloads
prop_encoder_rejects_nan :: Property
prop_encoder_rejects_nan =
  let nan = 0x7ff8000000000000
  in case encodeSnapshot (mkFloatSnapshot nan) of
       Left EncodeFloatNaNOrInfinity -> property True
       Left err -> counterexample ("unexpected error: " ++ show err) False
       Right _ -> counterexample "encoder allowed NaN" False

genText :: Gen T.Text
genText =
  frequency
    [ (3, T.pack <$> listOf (elements ascii))
    , (1, pure (T.pack "e\x0301"))
    ]
  where
    ascii = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ [' ', '-', '_']

genSnapshot :: Gen Snapshot
genSnapshot = do
  n <- chooseInt (0, 3)
  ents <- mapM genEntity [1..n]
  pure (Snapshot 0 ents zeroHash)

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
