module Main (main) where

import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Union (unionWorkSets)
import Snapshot.Scheduler.Core (scheduleStep)

import qualified Data.ByteString as BS
import Data.Word (Word8)
import Test.QuickCheck

main :: IO ()
main = do
  let args = stdArgs { maxSuccess = 50, maxSize = 10 }
  runQC args "union_commutative" prop_union_commutative
  runQC args "union_associative" prop_union_associative
  runQC args "schedule_deterministic" prop_schedule_deterministic

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  quickCheckWith args prop

prop_union_commutative :: Property
prop_union_commutative =
  forAll genWorkSet $ \a ->
    forAll genWorkSet $ \b ->
      unionEq (unionWorkSets a b) (unionWorkSets b a)

prop_union_associative :: Property
prop_union_associative =
  forAll genWorkSet $ \a ->
    forAll genWorkSet $ \b ->
      forAll genWorkSet $ \c ->
        let left = unionWorkSets a b >>= \ab -> unionWorkSets (unCanonicalWorkSet ab) c
            right = unionWorkSets b c >>= \bc -> unionWorkSets a (unCanonicalWorkSet bc)
        in unionEq left right

prop_schedule_deterministic :: Property
prop_schedule_deterministic =
  forAll genWorkSet $ \ws ->
    scheduleStep defaultParams defaultState ws === scheduleStep defaultParams defaultState ws

unionEq :: Either ScheduleError CanonicalWorkSet -> Either ScheduleError CanonicalWorkSet -> Property
unionEq (Left e1) (Left e2) = e1 === e2
unionEq (Right a) (Right b) = unCanonicalWorkSet a === unCanonicalWorkSet b
unionEq _ _ = property False

genWorkSet :: Gen [WorkItem]
genWorkSet = do
  ids <- sublistOf ([1..6] :: [Word8])
  pure (map mkItem ids)

mkItem :: Word8 -> WorkItem
mkItem n =
  let cell = Cell 0 0 1 (-10) 10 0
      wid = BS.replicate 32 n
      instr = mkInstrStream (fromIntegral n)
  in WorkItem wid cell maxBound (fromIntegral n) 1 instr

mkInstrStream :: Int -> BS.ByteString
mkInstrStream _n =
  let instr = BS.pack [1,0,0,0,0,0,0,0] -- NOP instruction bytes (len=0)
      stream = BS.pack [1,0,0,0,8,0,0,0] <> instr
  in stream
