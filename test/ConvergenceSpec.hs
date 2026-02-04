module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Scheduler.Core (scheduleStep)
import Snapshot.Scheduler.Types
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..))

import qualified Data.ByteString as BS
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)

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

  unioned <- case canonicalUnion wa wb of
    Left msg -> error ("union failed: " ++ msg)
    Right w -> pure w

  (batchBytes, _) <- case scheduleStep defaultParams defaultState unioned of
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
  case canonicalUnion wa wb of
    Left _ -> pure ()
    Right _ -> error "collision union unexpectedly succeeded"

canonicalUnion :: [WorkItem] -> [WorkItem] -> Either String [WorkItem]
canonicalUnion a b =
  let combined = a ++ b
      mpOrErr = foldl insert (Right Map.empty) combined
  in case mpOrErr of
       Left msg -> Left msg
       Right mp -> Right (List.sortBy compareWorkItem (Map.elems mp))
  where
    insert acc w =
      case acc of
        Left msg -> Left msg
        Right m ->
          case Map.lookup (workId w) m of
            Nothing -> Right (Map.insert (workId w) w m)
            Just w' ->
              if w' == w
                then Right m
                else Left "duplicate work_id with different bytes"

compareWorkItem :: WorkItem -> WorkItem -> Ordering
compareWorkItem x y = compare (workKey x, workId x) (workKey y, workId y)

workKey :: WorkItem -> (Int, Word32, Word64, Word32, BS.ByteString)
workKey w =
  ( fromIntegral (cellTier (workCell w))
  , negate32 (workPriority w)
  , workDeadline w
  , workCost w
  , workId w
  )

negate32 :: Word32 -> Word32
negate32 w = maxBound - w
