module Main (main) where

import Snapshot.Decode (decodeSnapshot, decodeSection)
import Snapshot.Encode (encodeSnapshot, encodeSection)
import Snapshot.Errors (DecodeError(..))

import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Control.Monad (forM_, when)
import Data.Bits ((.|.), shiftL)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let good =
        [ "test/golden/empty.csnp"
        , "test/golden/one-entity.csnp"
        ]
  let goodSections =
        [ "test/golden/one-entity.cspt"
        ]
  let goodHashes =
        [ ("test/golden/empty.csnp", "test/golden/empty.hash")
        , ("test/golden/one-entity.csnp", "test/golden/one-entity.hash")
        , ("test/golden/one-entity.cspt", "test/golden/one-entity.cspt.hash")
        ]
  let badExpected =
        [ ("test/bad/dup-id.csnp", [ErrEntityIdsNotAscending])
        , ("test/bad/unsorted.csnp", [ErrEntityIdsNotAscending])
        , ("test/bad/invalid-utf8.csnp", [ErrInvalidUtf8, ErrUtf8Bom, ErrNotNfc])
        , ("test/bad/nan.csnp", [ErrFloatNaNOrInfinity])
        , ("test/bad/bad-hash.csnp", [ErrHashMismatch])
        , ("test/bad/bad-magic.csnp", [ErrInvalidMagic])
        ]
  let badSectionsExpected =
        [ ("test/bad/bad-magic.cspt", [ErrInvalidMagic])
        , ("test/bad/bad-hash.cspt", [ErrHashMismatch])
        , ("test/bad/tick-range.cspt", [ErrTickRangeInvalid])
        , ("test/bad/entity-range.cspt", [ErrEntityRangeInvalid])
        , ("test/bad/entity-out-of-range.cspt", [ErrEntityOutOfRange])
        , ("test/bad/unsorted.cspt", [ErrEntityIdsNotAscending])
        ]

  forM_ good goldenRoundtrip
  forM_ good goldenIdempotent
  forM_ goodSections goldenSectionRoundtrip
  forM_ goodSections goldenSectionIdempotent
  forM_ goodHashes goldenHash
  forM_ badExpected rejectSnapshotAs
  forM_ badSectionsExpected rejectSectionAs

  putStrLn "Golden vectors: OK"

-- | Decode then re-encode; bytes must match exactly.
goldenRoundtrip :: FilePath -> IO ()
goldenRoundtrip fp = do
  bytes <- BS.readFile fp
  case decodeSnapshot bytes of
    Left err -> die ("decode failed for " ++ fp ++ ": " ++ show err)
    Right snap ->
      case encodeSnapshot snap of
        Left err -> die ("encode failed for " ++ fp ++ ": " ++ show err)
        Right out ->
          if out == bytes && BS.length out == BS.length bytes
            then return ()
            else do
              putStrLn ("roundtrip mismatch: " ++ fp)
              putStrLn ("original size: " ++ show (BS.length bytes))
              putStrLn ("encoded  size: " ++ show (BS.length out))
              die "bytes differ"

-- | Encoder idempotency: encode ∘ decode ∘ encode == encode
goldenIdempotent :: FilePath -> IO ()
goldenIdempotent fp = do
  bytes <- BS.readFile fp
  snap <- case decodeSnapshot bytes of
    Left err -> die ("decode failed for " ++ fp ++ ": " ++ show err)
    Right s -> pure s

  out1 <- case encodeSnapshot snap of
    Left err -> die ("encode failed for " ++ fp ++ ": " ++ show err)
    Right b -> pure b

  snap2 <- case decodeSnapshot out1 of
    Left err -> die ("decode failed after encode for " ++ fp ++ ": " ++ show err)
    Right s -> pure s

  out2 <- case encodeSnapshot snap2 of
    Left err -> die ("encode failed after decode for " ++ fp ++ ": " ++ show err)
    Right b -> pure b

  if out2 == out1
    then return ()
    else die ("idempotency failed (encode∘decode∘encode != encode): " ++ fp)

-- | Decode then re-encode; bytes must match exactly (CSPT).
goldenSectionRoundtrip :: FilePath -> IO ()
goldenSectionRoundtrip fp = do
  bytes <- BS.readFile fp
  case decodeSection bytes of
    Left err -> die ("decode failed for " ++ fp ++ ": " ++ show err)
    Right sec ->
      case encodeSection sec of
        Left err -> die ("encode failed for " ++ fp ++ ": " ++ show err)
        Right out ->
          if out == bytes && BS.length out == BS.length bytes
            then return ()
            else do
              putStrLn ("roundtrip mismatch: " ++ fp)
              putStrLn ("original size: " ++ show (BS.length bytes))
              putStrLn ("encoded  size: " ++ show (BS.length out))
              die "bytes differ"

-- | Encoder idempotency for CSPT.
goldenSectionIdempotent :: FilePath -> IO ()
goldenSectionIdempotent fp = do
  bytes <- BS.readFile fp
  sec <- case decodeSection bytes of
    Left err -> die ("decode failed for " ++ fp ++ ": " ++ show err)
    Right s -> pure s

  out1 <- case encodeSection sec of
    Left err -> die ("encode failed for " ++ fp ++ ": " ++ show err)
    Right b -> pure b

  sec2 <- case decodeSection out1 of
    Left err -> die ("decode failed after encode for " ++ fp ++ ": " ++ show err)
    Right s -> pure s

  out2 <- case encodeSection sec2 of
    Left err -> die ("encode failed after decode for " ++ fp ++ ": " ++ show err)
    Right b -> pure b

  if out2 == out1
    then return ()
    else die ("idempotency failed (encode∘decode∘encode != encode): " ++ fp)

-- | Hash lock: file hash must match the stored golden hash.
goldenHash :: (FilePath, FilePath) -> IO ()
goldenHash (fp, hashPath) = do
  bytes <- BS.readFile fp
  when (BS.length bytes < 32) $
    die ("file too small for hash: " ++ fp)
  expectedHex <- BSC.readFile hashPath
  case hexDecode (BSC.filter (/= '\n') expectedHex) of
    Left err -> die ("bad hash file " ++ hashPath ++ ": " ++ err)
    Right expected -> do
      let actual = SHA.hash (BS.take (BS.length bytes - 32) bytes)
      if actual == expected
        then return ()
        else die ("hash mismatch for " ++ fp)

-- | Invalid snapshots must be rejected with the expected error class.
rejectSnapshotAs :: (FilePath, [DecodeError]) -> IO ()
rejectSnapshotAs (fp, expectedErrs) = do
  bytes <- BS.readFile fp
  case decodeSnapshot bytes of
    Left err -> do
      putStrLn ("rejected (as expected): " ++ fp ++ " -> " ++ show err)
      if err `elem` expectedErrs
        then return ()
        else die ("wrong rejection class for " ++ fp
               ++ "\n  expected one of: " ++ show expectedErrs
               ++ "\n  actual:         " ++ show err)
    Right _ -> die ("expected rejection for " ++ fp)

-- | Invalid CSPT sections must be rejected with the expected error class.
rejectSectionAs :: (FilePath, [DecodeError]) -> IO ()
rejectSectionAs (fp, expectedErrs) = do
  bytes <- BS.readFile fp
  case decodeSection bytes of
    Left err -> do
      putStrLn ("rejected (as expected): " ++ fp ++ " -> " ++ show err)
      if err `elem` expectedErrs
        then return ()
        else die ("wrong rejection class for " ++ fp
               ++ "\n  expected one of: " ++ show expectedErrs
               ++ "\n  actual:         " ++ show err)
    Right _ -> die ("expected rejection for " ++ fp)

hexDecode :: BS.ByteString -> Either String BS.ByteString
hexDecode bs
  | BS.length bs `mod` 2 /= 0 = Left "hex length must be even"
  | otherwise = go bs mempty
  where
    go input acc
      | BS.null input = Right acc
      | otherwise = do
          let (a, rest1) = (BS.head input, BS.tail input)
          if BS.null rest1 then Left "hex length must be even" else do
            let b = BS.head rest1
            hi <- hexNibble a
            lo <- hexNibble b
            let byte = (hi `shiftL` 4) .|. lo
            go (BS.drop 2 input) (BS.snoc acc byte)

    hexNibble c
      | c >= 48 && c <= 57 = Right (fromIntegral (c - 48))
      | c >= 65 && c <= 70 = Right (fromIntegral (c - 55))
      | c >= 97 && c <= 102 = Right (fromIntegral (c - 87))
      | otherwise = Left "invalid hex digit"


-- | Fail fast for test harness.
die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
