module Main (main) where

import Snapshot.Universe.Core
import Snapshot.Universe.Types

import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as BS
import Data.Bits ((.|.), shiftL)
import System.Exit (exitFailure)

main :: IO ()
main = do
  goldenRoundtrip "test/golden-instrstream/basic.instrstream" "test/golden-instrstream/basic.hash"

  rejectStreamAs "test/bad-instrstream/stream-len-mismatch.instrstream" ErrMalformedInstruction
  rejectStreamAs "test/bad-instrstream/stream-overflow.instrstream" ErrLimitExceeded
  rejectStreamAs "test/bad-instrstream/stream-truncated.instrstream" ErrMalformedInstruction

  putStrLn "Instruction stream golden: OK"

goldenRoundtrip :: FilePath -> FilePath -> IO ()
goldenRoundtrip fp hashPath = do
  bytes <- BS.readFile fp
  case decodeStream bytes of
    Left err -> die ("decode failed for " ++ fp ++ ": " ++ show err)
    Right instrs ->
      case encodeStream instrs of
        Left err -> die ("encode failed for " ++ fp ++ ": " ++ show err)
        Right out ->
          if out == bytes
            then return ()
            else die ("roundtrip mismatch: " ++ fp)
  expectedHex <- BS.readFile hashPath
  case hexDecode (BS.filter (/= 10) expectedHex) of
    Left msg -> die ("bad hash file " ++ hashPath ++ ": " ++ msg)
    Right expected ->
      if hashBytes bytes == expected
        then return ()
        else die ("hash mismatch for " ++ fp)

rejectStreamAs :: FilePath -> HaltReason -> IO ()
rejectStreamAs fp expected = do
  bytes <- BS.readFile fp
  case decodeStream bytes of
    Left err | err == expected -> return ()
    Left err -> die ("wrong error for " ++ fp ++ ": " ++ show err)
    Right _ -> die ("expected rejection for " ++ fp)

hashBytes :: BS.ByteString -> BS.ByteString
hashBytes = SHA.hash

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure

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
