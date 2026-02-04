module Main (main) where

import Snapshot.Types
import Snapshot.Universe.Core
import Snapshot.Universe.Types
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Decode (decodeSnapshot)

import Data.Binary.Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Test.QuickCheck
import Data.Bits ((.|.), shiftL)

main :: IO ()
main = do
  let args = stdArgs { maxSuccess = 100, maxSize = 20 }
  runQC args "determinism" prop_determinism
  runQC args "replay_law" prop_replay_law
  runQC args "step_canonical" prop_step_canonical
  testMalformedFlags
  testMalformedBeatsSemantic
  testLimitBeatsSemantic
  testAdvanceTickAdminRequired
  testAdvanceTickOverflow
  testStreamLengthMismatch

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  quickCheckWith args prop

prop_determinism :: Property
prop_determinism =
  forAll genSnapshot $ \snap ->
    forAll genInstr $ \instr ->
      step snap fullAuth instr === step snap fullAuth instr

prop_replay_law :: Property
prop_replay_law =
  forAll genSnapshot $ \snap ->
    forAll genInstr $ \i1 ->
      forAll genInstr $ \i2 ->
        let (r1, s1) = applyInstructions snap fullAuth [i1, i2]
            (rStep1, sStep1) = step snap fullAuth i1
            (r2, s2) = case rStep1 of
              Next -> step sStep1 fullAuth i2
              Halt reason -> (Halt reason, sStep1)
        in (r1, s1) === (r2, s2)

prop_step_canonical :: Property
prop_step_canonical =
  forAll genSnapshot $ \snap ->
    forAll genInstr $ \instr ->
      case step snap fullAuth instr of
        (Next, snap') ->
          case encodeSnapshot snap' of
            Left _ -> counterexample "encodeSnapshot failed" False
            Right bytes ->
              case decodeSnapshot bytes of
                Left _ -> counterexample "decodeSnapshot failed" False
                Right snap'' -> snap'' === snap'
        (Halt _, snap') -> snap' === snap

genSnapshot :: Gen Snapshot
genSnapshot = do
  tick <- chooseInt (0, 1000)
  pure (Snapshot (fromIntegral tick) [] (Hash (BS.replicate 32 0)))

genInstr :: Gen Instruction
genInstr =
  oneof
    [ pure (Instruction opcodeNOP 0 BS.empty)
    , do
        delta <- chooseInt (1, 100)
        let payload = BL.toStrict (runPut (putWord64le (fromIntegral delta)))
        pure (Instruction opcodeAdvanceTick 0 payload)
    ]

fullAuth :: AuthorityMask
fullAuth = AuthorityMask ((1 `shiftL` 0) .|. (1 `shiftL` 1) .|. (1 `shiftL` 2) .|. (1 `shiftL` 3))

testMalformedFlags :: IO ()
testMalformedFlags =
  case decodeInstruction (BL.toStrict (runPut (putWord16le 0x0001 >> putWord16le 1 >> putWord32le 0))) of
    Left ErrMalformedInstruction -> return ()
    Left err -> fail ("expected ErrMalformedInstruction, got " ++ show err)
    Right _ -> fail "expected failure for nonzero flags"

testStreamLengthMismatch :: IO ()
testStreamLengthMismatch =
  let instr = BL.toStrict (runPut (putWord16le 0x0001 >> putWord16le 0 >> putWord32le 0))
      stream = BL.toStrict (runPut (putWord32le 1 >> putWord32le 9 >> putByteString instr))
  in case decodeStream stream of
       Left ErrMalformedInstruction -> return ()
       Left err -> fail ("expected ErrMalformedInstruction, got " ++ show err)
       Right _ -> fail "expected failure for length mismatch"

testMalformedBeatsSemantic :: IO ()
testMalformedBeatsSemantic =
  let payload = BS.pack [0xFF] -- invalid UTF-8 if interpreted
      instr = BL.toStrict (runPut (putWord16le 0x2001 >> putWord16le 0 >> putWord32le 5 >> putByteString payload))
  in case decodeInstruction instr of
       Left ErrMalformedInstruction -> return ()
       Left err -> fail ("expected ErrMalformedInstruction, got " ++ show err)
       Right _ -> fail "expected malformed instruction to fail"

testLimitBeatsSemantic :: IO ()
testLimitBeatsSemantic =
  let stream = BL.toStrict (runPut (putWord32le 100001 >> putWord32le 1 >> putByteString (BS.pack [0x00])))
  in case decodeStream stream of
       Left ErrLimitExceeded -> return ()
       Left err -> fail ("expected ErrLimitExceeded, got " ++ show err)
       Right _ -> fail "expected limit failure for stream"

testAdvanceTickAdminRequired :: IO ()
testAdvanceTickAdminRequired =
  let instr = Instruction opcodeAdvanceTick 0 (BL.toStrict (runPut (putWord64le 1)))
      (res, _) = step (Snapshot 0 [] (Hash (BS.replicate 32 0))) (AuthorityMask 0) instr
  in case res of
       Halt ErrUnauthorized -> return ()
       _ -> fail "expected ErrUnauthorized for ADVANCE_TICK without ADMIN"

testAdvanceTickOverflow :: IO ()
testAdvanceTickOverflow =
  let instr = Instruction opcodeAdvanceTick 0 (BL.toStrict (runPut (putWord64le 1)))
      snap = Snapshot maxBound [] (Hash (BS.replicate 32 0))
      (res, snap') = step snap fullAuth instr
  in case res of
       Halt ErrInvalidTick | snap' == snap -> return ()
       _ -> fail "expected ErrInvalidTick and unchanged snapshot on overflow"
