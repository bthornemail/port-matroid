module Snapshot.Scheduler.Core
  ( scheduleStep
  ) where

import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Validate (validateWorkSet)
import Snapshot.Universe.Core (decodeStream, encodeStream)
import Snapshot.Universe.Types (Instruction)
import Data.Int (Int64)

import qualified Data.ByteString as BS
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32, Word64, Word8)

scheduleStep :: SchedulerParams -> SchedulerState -> [WorkItem] -> Either ScheduleError (BS.ByteString, SchedulerState)
scheduleStep params state items = do
  let canon = canonicalizeWorkSet items
  validated <- validateWorkSet (unCanonicalWorkSet canon)
  let grouped = groupByCell validated
  let cells = rotateCells (cursorCell state) (Map.keys grouped)
  let queues = Map.map sortQueue grouped
  let (result, lastCell) = buildBatch params cells queues Set.empty [] 0 0 0 Nothing
  batchInstrs <- result
  batchBytes <- mapEncode (encodeStream batchInstrs)
  let nextCursor = case lastCell of
        Nothing -> cursorCell state
        Just c -> Just c
  let nextState = SchedulerState { cursorCell = nextCursor }
  return (batchBytes, nextState)

mapEncode :: Either a BS.ByteString -> Either ScheduleError BS.ByteString
mapEncode (Left _) = Left SchErrInternal
mapEncode (Right b) = Right b
groupByCell :: [(WorkItem, [Int64])] -> Map.Map Cell [(WorkItem, [Int64])]
groupByCell = foldl insert Map.empty
  where
    insert mp (w, t) = Map.insertWith (++) (workCell w) [(w, t)] mp

sortQueue :: [(WorkItem, [Int64])] -> [(WorkItem, [Int64])]
sortQueue = List.sortBy compareWork
  where
    compareWork (a, _) (b, _) = compare (workKey a) (workKey b)

rotateCells :: Maybe Cell -> [Cell] -> [Cell]
rotateCells _ [] = []
rotateCells Nothing cells = List.sort cells
rotateCells (Just c) cells =
  let sorted = List.sort cells
      (before, after) = List.break (> c) sorted
  in case after of
       [] -> sorted
       (x:xs) -> xs ++ before ++ [x]

buildBatch
  :: SchedulerParams
  -> [Cell]
  -> Map.Map Cell [(WorkItem, [Int64])]
  -> Set.Set Int64
  -> [Instruction]
  -> Word32
  -> Word32
  -> Word32
  -> Maybe Cell
  -> (Either ScheduleError [Instruction], Maybe Cell)
buildBatch params cells queues touched acc cost skips inspected lastAccepted =
  case nextCandidate cells queues of
    Nothing -> (Right acc, lastAccepted)
    Just (cell, (w, t), queues') ->
      if inspected >= maxWork params
        then (Left SchErrLimitExceeded, lastAccepted)
      else if skips >= maxSkip params
        then (Left SchErrLimitExceeded, lastAccepted)
      else case addCost cost (workCost w) of
          Left _ -> (Left SchErrInternal, lastAccepted)
          Right cost' ->
            if cost' > sliceBudget params
              then (Right acc, lastAccepted)
              else if conflicts touched t
                then buildBatch params cells (pop cell queues') touched acc cost (skips + 1) (inspected + 1) lastAccepted
                else case decodeStream (workInstrStream w) of
                  Left _ -> (Left SchErrMalformedWork, lastAccepted)
                  Right instrs ->
                    let touched' = addTouches touched t
                        acc' = acc ++ instrs
                        queues'' = pop cell queues'
                    in buildBatch params cells queues'' touched' acc' cost' skips (inspected + 1) (Just cell)

nextCandidate :: [Cell] -> Map.Map Cell [(WorkItem, [Int64])] -> Maybe (Cell, (WorkItem, [Int64]), Map.Map Cell [(WorkItem, [Int64])])
nextCandidate cells queues =
  let heads = [ (cell, head qs) | cell <- cells, Just qs <- [Map.lookup cell queues], not (null qs) ]
  in case heads of
       [] -> Nothing
       _ ->
         let (cell, item) = List.minimumBy compareCandidate heads
         in Just (cell, item, queues)
  where
    compareCandidate (c1, (w1, _)) (c2, (w2, _)) =
      compare (workKey w1, c1) (workKey w2, c2)

pop :: Cell -> Map.Map Cell [(WorkItem, [Int64])] -> Map.Map Cell [(WorkItem, [Int64])]
pop cell mp =
  case Map.lookup cell mp of
    Nothing -> mp
    Just (_:rest) ->
      if null rest then Map.delete cell mp else Map.insert cell rest mp
    Just [] -> mp

conflicts :: Set.Set Int64 -> [Int64] -> Bool
conflicts touched = any (`Set.member` touched)

addTouches :: Set.Set Int64 -> [Int64] -> Set.Set Int64
addTouches = List.foldl' (flip Set.insert)

addCost :: Word32 -> Word32 -> Either () Word32
addCost a b =
  if a > maxBound - b then Left () else Right (a + b)
