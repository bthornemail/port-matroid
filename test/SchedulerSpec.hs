module Main (main) where

import Snapshot.Scheduler.Core (scheduleStep)
import Snapshot.Scheduler.Types
import qualified Data.ByteString as BS
import Test.QuickCheck

main :: IO ()
main = do
  let args = stdArgs { maxSuccess = 50, maxSize = 10 }
  runQC args "permutation_determinism" prop_permutation_determinism
  runQC args "budget_monotonicity" prop_budget_monotonicity

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  quickCheckWith args prop

prop_permutation_determinism :: Property
prop_permutation_determinism =
  forAll genWorkSet $ \ws ->
    forAll (shuffle ws) $ \ws' ->
      scheduleStep defaultParams defaultState ws === scheduleStep defaultParams defaultState ws'

prop_budget_monotonicity :: Property
prop_budget_monotonicity =
  forAll genWorkSet $ \ws ->
    case scheduleStep (defaultParams { sliceBudget = 1 }) defaultState ws of
      Left _ -> property True
      Right (batch1, _) ->
        case scheduleStep (defaultParams { sliceBudget = 2 }) defaultState ws of
          Left _ -> property True
          Right (batch2, _) ->
            batch1 `BS.isPrefixOf` batch2 === True

genWorkSet :: Gen [WorkItem]
genWorkSet = do
  let cell = Cell 0 0 1 (-10) 10 0
  wid1 <- BS.pack <$> vectorOf 32 (elements [1,2,3,4])
  wid2 <- BS.pack <$> vectorOf 32 (elements [5,6,7,8])
  let item1 = WorkItem wid1 cell maxBound 10 1 (mkInstrStream 1)
  let item2 = WorkItem wid2 cell maxBound 5 1 (mkInstrStream 2)
  pure [item1, item2]

mkInstrStream :: Int -> BS.ByteString
mkInstrStream n =
  let instr = BS.pack [1,0,0,0,0,0,0,0] -- NOP instruction bytes (len=0)
      stream = BS.pack [1,0,0,0,8,0,0,0] <> instr
  in stream
