module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Types (Snapshot)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Scheduler.Core (scheduleStep)
import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Union (unionWorkSets)
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..))

import qualified Data.ByteString as BS

main :: IO ()
main = do
  beforeBytes <- BS.readFile "test/convergence/before.csnp"
  afterBytes <- BS.readFile "test/convergence/after.csnp"
  batchExpected <- BS.readFile "test/convergence/batch.instrstream"
  waBytes <- BS.readFile "test/convergence/peer-a.workset"
  wbBytes <- BS.readFile "test/convergence/peer-b.workset"

  beforeSnap <- case decodeSnapshot beforeBytes of
    Left err -> error ("decode before snapshot failed: " ++ show err)
    Right s -> pure s

  wa <- case decodeWorkSet waBytes of
    Left err -> error ("decode peer-a workset failed: " ++ show err)
    Right w -> pure w
  wb <- case decodeWorkSet wbBytes of
    Left err -> error ("decode peer-b workset failed: " ++ show err)
    Right w -> pure w

  unioned <- case unionWorkSets wa wb of
    Left err -> error ("union failed: " ++ show err)
    Right w -> pure w

  (batchBytes, _) <- case scheduleStep defaultParams defaultState (unCanonicalWorkSet unioned) of
    Left err -> error ("scheduleStep failed: " ++ show err)
    Right v -> pure v

  if batchBytes /= batchExpected
    then error "batch bytes mismatch"
    else do
      instrs <- case decodeStream batchBytes of
        Left err -> error ("decodeStream failed: " ++ show err)
        Right xs -> pure xs
      let auth = AuthorityMask 0xF
      case applyInstructions beforeSnap auth instrs of
        (Halt r, _) -> error ("applyInstructions halted: " ++ show r)
        (Next, snap') ->
          case encodeSnapshot snap' of
            Left err -> error ("encodeSnapshot failed: " ++ show err)
            Right bytes ->
              if bytes /= afterBytes
                then error "after snapshot mismatch"
                else do
                  runCollisionCase
                  runDuplicateOkCase
                  runMultiShardCase batchExpected beforeSnap afterBytes
                  putStrLn "OK"

runCollisionCase :: IO ()
runCollisionCase = do
  waBytes <- BS.readFile "test/convergence/collision-a.workset"
  wbBytes <- BS.readFile "test/convergence/collision-b.workset"
  wa <- case decodeWorkSet waBytes of
    Left err -> error ("decode collision-a failed: " ++ show err)
    Right w -> pure w
  wb <- case decodeWorkSet wbBytes of
    Left err -> error ("decode collision-b failed: " ++ show err)
    Right w -> pure w
  case unionWorkSets wa wb of
    Left _ -> pure ()
    Right _ -> error "collision union unexpectedly succeeded"

runDuplicateOkCase :: IO ()
runDuplicateOkCase = do
  waBytes <- BS.readFile "test/convergence/dupe-ok-a.workset"
  wbBytes <- BS.readFile "test/convergence/dupe-ok-b.workset"
  wa <- case decodeWorkSet waBytes of
    Left err -> error ("decode dupe-ok-a failed: " ++ show err)
    Right w -> pure w
  wb <- case decodeWorkSet wbBytes of
    Left err -> error ("decode dupe-ok-b failed: " ++ show err)
    Right w -> pure w
  case unionWorkSets wa wb of
    Left err -> error ("duplicate ok union failed: " ++ show err)
    Right ws ->
      if length (unCanonicalWorkSet ws) /= 1
        then error "duplicate ok union wrong size"
        else pure ()

runMultiShardCase :: BS.ByteString -> Snapshot -> BS.ByteString -> IO ()
runMultiShardCase batchExpected beforeSnap afterBytes = do
  waBytes <- BS.readFile "test/convergence/multishard-a.workset"
  wbBytes <- BS.readFile "test/convergence/multishard-b.workset"
  wa <- case decodeWorkSet waBytes of
    Left err -> error ("decode multishard-a failed: " ++ show err)
    Right w -> pure w
  wb <- case decodeWorkSet wbBytes of
    Left err -> error ("decode multishard-b failed: " ++ show err)
    Right w -> pure w
  unioned <- case unionWorkSets wa wb of
    Left err -> error ("multishard union failed: " ++ show err)
    Right w -> pure w
  (batchBytes, _) <- case scheduleStep defaultParams defaultState (unCanonicalWorkSet unioned) of
    Left err -> error ("multishard scheduleStep failed: " ++ show err)
    Right v -> pure v
  if batchBytes /= batchExpected
    then error "multishard batch bytes mismatch"
    else do
      instrs <- case decodeStream batchBytes of
        Left err -> error ("multishard decodeStream failed: " ++ show err)
        Right xs -> pure xs
      let auth = AuthorityMask 0xF
      case applyInstructions beforeSnap auth instrs of
        (Halt r, _) -> error ("multishard applyInstructions halted: " ++ show r)
        (Next, snap') ->
          case encodeSnapshot snap' of
            Left err -> error ("multishard encodeSnapshot failed: " ++ show err)
            Right bytes ->
              if bytes /= afterBytes
                then error "multishard after snapshot mismatch"
                else pure ()
