module Snapshot.Scheduler.Validate
  ( validateWorkSet
  ) where

import Snapshot.Scheduler.Types
import Snapshot.Universe.Core (decodeStream)
import Snapshot.Universe.Types (Instruction(..), Opcode(..))

import qualified Data.ByteString as BS
import qualified Data.Set as Set
import Data.Int (Int64)
import Data.Bits (shiftL)
import Data.List (nub, sort)
import Data.List (foldl')

validateWorkSet :: [WorkItem] -> Either ScheduleError [(WorkItem, [Int64])]
validateWorkSet items = do
  ensureCellsValid items
  ensureNoCellOverlap items
  let dup = hasDuplicateIds items
  let (malformed, validated) = mapAccumItems items
  if anyOutOfRange validated
    then Left SchErrOutOfRange
    else if dup
      then Left SchErrDuplicateWorkId
      else if malformed
        then Left SchErrMalformedWork
        else Right validated

validateItem :: WorkItem -> (Bool, (WorkItem, [Int64]))
validateItem item =
  case touchSet item of
    Left _ -> (True, (item, []))
    Right touches -> (False, (item, touches))

hasDuplicateIds :: [WorkItem] -> Bool
hasDuplicateIds items =
  let ids = map workId items
      s = foldl' (flip Set.insert) Set.empty ids
  in length ids /= Set.size s

ensureNoCellOverlap :: [WorkItem] -> Either ScheduleError ()
ensureNoCellOverlap items =
  if anyOverlap (map workCell items)
    then Left SchErrInvalidCell
    else Right ()
  where
    anyOverlap [] = False
    anyOverlap (c:cs) =
      any (cellsOverlap c) cs || anyOverlap cs

    cellsOverlap a b =
      a /= b &&
      cellShard a == cellShard b &&
      cellTier a == cellTier b &&
      cellT0 a < cellT1 b && cellT0 b < cellT1 a &&
      cellE0 a <= cellE1 b && cellE0 b <= cellE1 a

mapAccumItems :: [WorkItem] -> (Bool, [(WorkItem, [Int64])])
mapAccumItems = foldl' step (False, [])
  where
    step (bad, acc) item =
      let (m, v) = validateItem item
      in (bad || m, acc ++ [v])

anyOutOfRange :: [(WorkItem, [Int64])] -> Bool
anyOutOfRange = any (\(item, touches) ->
  let c = workCell item
  in any (\eid -> eid < cellE0 c || eid > cellE1 c) touches)

ensureCellsValid :: [WorkItem] -> Either ScheduleError ()
ensureCellsValid items =
  if any invalidCell (map workCell items)
    then Left SchErrInvalidCell
    else Right ()
  where
    invalidCell c = cellT0 c >= cellT1 c || cellE0 c > cellE1 c

touchSet :: WorkItem -> Either ScheduleError [Int64]
touchSet item =
  case decodeStream (workInstrStream item) of
    Left _ -> Left SchErrMalformedWork
    Right instrs -> Right (canonicalize (collect instrs []))
  where
    collect [] acc = acc
    collect (i:is) acc =
      case instrOpcode i of
        Opcode 0x1001 -> case getEntityId i of
          Just eid -> collect is (eid : acc)
          Nothing -> collect is acc
        Opcode 0x1002 -> case getEntityId i of
          Just eid -> collect is (eid : acc)
          Nothing -> collect is acc
        Opcode 0x2001 -> case getEntityId i of
          Just eid -> collect is (eid : acc)
          Nothing -> collect is acc
        Opcode 0x2002 -> case getEntityId i of
          Just eid -> collect is (eid : acc)
          Nothing -> collect is acc
        _ -> collect is acc

    canonicalize = sort . nub

getEntityId :: Instruction -> Maybe Int64
getEntityId instr =
  let bs = instrPayload instr
  in if BS.length bs < 8
       then Nothing
       else Just (bytesToInt64 (BS.take 8 bs))

bytesToInt64 :: BS.ByteString -> Int64
bytesToInt64 bs =
  let b0 = fromIntegral (BS.index bs 0) :: Int64
      b1 = fromIntegral (BS.index bs 1) :: Int64
      b2 = fromIntegral (BS.index bs 2) :: Int64
      b3 = fromIntegral (BS.index bs 3) :: Int64
      b4 = fromIntegral (BS.index bs 4) :: Int64
      b5 = fromIntegral (BS.index bs 5) :: Int64
      b6 = fromIntegral (BS.index bs 6) :: Int64
      b7 = fromIntegral (BS.index bs 7) :: Int64
  in  b0
   + (b1 `shiftL` 8)
   + (b2 `shiftL` 16)
   + (b3 `shiftL` 24)
   + (b4 `shiftL` 32)
   + (b5 `shiftL` 40)
   + (b6 `shiftL` 48)
   + (b7 `shiftL` 56)
