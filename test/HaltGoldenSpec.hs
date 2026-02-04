module Main (main) where

import Snapshot.Universe.Core (haltReasonToCode, codeToHaltReason)
import Snapshot.Universe.Types (HaltReason(..))

import qualified Data.ByteString as BS
import Data.Bits ((.&.), shiftR)
import System.Exit (exitFailure)

main :: IO ()
main = do
  roundtripAll
  golden "test/golden-halt/unknown-opcode.halt" ErrUnknownOpcode
  golden "test/golden-halt/unauthorized.halt" ErrUnauthorized
  golden "test/golden-halt/overflow.halt" ErrInvalidTick
  golden "test/golden-halt/malformed.halt" ErrMalformedInstruction
  putStrLn "Halt golden: OK"

roundtripAll :: IO ()
roundtripAll = mapM_ check
  [ ErrUnknownOpcode
  , ErrUnauthorized
  , ErrEntityExists
  , ErrEntityMissing
  , ErrInvalidKey
  , ErrInvalidValue
  , ErrInvalidType
  , ErrInvalidTick
  , ErrCanonicalViolation
  , ErrLimitExceeded
  , ErrInternalInvariant
  , ErrMalformedInstruction
  ]
  where
    check r =
      case codeToHaltReason (haltReasonToCode r) of
        Just r' | r' == r -> return ()
        _ -> die ("roundtrip failed for " ++ show r)

golden :: FilePath -> HaltReason -> IO ()
golden fp reason = do
  bytes <- BS.readFile fp
  if bytes == codeBytes reason
    then return ()
    else die ("halt code mismatch: " ++ fp)

codeBytes :: HaltReason -> BS.ByteString
codeBytes r =
  let w = haltReasonToCode r
  in BS.pack [fromIntegral (w .&. 0xff), fromIntegral (w `shiftR` 8)]

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
