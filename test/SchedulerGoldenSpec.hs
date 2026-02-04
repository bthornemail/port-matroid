module Main (main) where

import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Scheduler.Core (scheduleStep)
import Snapshot.Scheduler.Types
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..))
import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)

import qualified Data.ByteString as BS
import Data.Bits ((.|.), shiftL)
import System.Exit (exitFailure)

main :: IO ()
main = do
  golden "test/golden-schedule/basic.before.csnp"
         "test/golden-schedule/basic.workset"
         "test/golden-schedule/basic.batch.instrstream"
         "test/golden-schedule/basic.after.csnp"
  putStrLn "Scheduler golden: OK"

golden :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
golden beforePath worksetPath batchPath afterPath = do
  beforeBytes <- BS.readFile beforePath
  worksetBytes <- BS.readFile worksetPath
  expectedBatch <- BS.readFile batchPath
  expectedAfter <- BS.readFile afterPath

  before <- case decodeSnapshot beforeBytes of
    Left err -> die ("decode before failed: " ++ show err)
    Right s -> pure s

  workset <- case decodeWorkSet worksetBytes of
    Left err -> die ("decode workset failed: " ++ show err)
    Right w -> pure w

  let params = defaultParams { sliceBudget = 1000 }
  let state = defaultState
  (batch, _) <- case scheduleStep params state workset of
    Left err -> die ("schedule failed: " ++ show err)
    Right r -> pure r

  if batch /= expectedBatch
    then die "batch mismatch"
    else return ()

  instrs <- case decodeStream batch of
    Left err -> die ("decode batch failed: " ++ show err)
    Right xs -> pure xs

  let (res, afterSnap) = applyInstructions before fullAuth instrs
  case res of
    Halt r -> die ("replay halted: " ++ show r)
    Next -> do
      out <- case encodeSnapshot afterSnap of
        Left err -> die ("encode after failed: " ++ show err)
        Right b -> pure b
      if out == expectedAfter
        then return ()
        else die "after snapshot mismatch"

fullAuth :: AuthorityMask
fullAuth = AuthorityMask ((1 `shiftL` 0) .|. (1 `shiftL` 1) .|. (1 `shiftL` 2) .|. (1 `shiftL` 3))

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
