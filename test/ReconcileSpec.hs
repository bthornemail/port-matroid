module Main (main) where

import Snapshot.Reconcile.Core (reconcile)
import Snapshot.Reconcile.Types (ReconcileError(..))
import Snapshot.Types
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Decode (decodeSnapshot)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import System.Exit (exitFailure)

main :: IO ()
main = do
  testMerge
  testConflict
  testPermutation
  testGluingRoundtrip
  testPriorityOrder
  putStrLn "Reconcile tests: OK"

testMerge :: IO ()
testMerge =
  case reconcile [secA, secB] of
    Left err -> die ("merge failed: " ++ show err)
    Right snap ->
      if snapEntities snap == [ent1, ent2]
        then return ()
        else die "merge produced unexpected entities"

testConflict :: IO ()
testConflict =
  case reconcile [secA, secConflict] of
    Left (ErrOverlapMismatch 1) -> return ()
    Left err -> die ("expected ErrOverlapMismatch, got " ++ show err)
    Right _ -> die "expected conflict to fail"

testPermutation :: IO ()
testPermutation =
  case (reconcile [secA, secB], reconcile [secB, secA]) of
    (Right s1, Right s2) ->
      if snapEntities s1 == snapEntities s2
        then return ()
        else die "permutation invariance failed"
    (Left e1, Left e2) ->
      if e1 == e2
        then return ()
        else die "permutation invariance errors differ"
    _ -> die "permutation invariance mixed success/failure"

testGluingRoundtrip :: IO ()
testGluingRoundtrip = do
  let snap = canonicalizeSnapshot (Snapshot 0 [ent1, ent2, ent3] (Hash (BS.replicate 32 0)))
  let sec1 =
        Section
          { secShard = 0
          , secTickStart = 0
          , secTickEnd = 1
          , secEntityMin = 1
          , secEntityMax = 2
          , secPriority = 0
          , secEntities = [ent1, ent2]
          , secHash = Hash (BS.replicate 32 0)
          }
      sec2 =
        Section
          { secShard = 0
          , secTickStart = 0
          , secTickEnd = 1
          , secEntityMin = 3
          , secEntityMax = 3
          , secPriority = 0
          , secEntities = [ent3]
          , secHash = Hash (BS.replicate 32 0)
          }
  case reconcile [sec1, sec2] of
    Left err -> die ("gluing failed: " ++ show err)
    Right out ->
      if encodeSnapshot out == encodeSnapshot snap
        then return ()
        else die "gluing roundtrip mismatch"

testPriorityOrder :: IO ()
testPriorityOrder = do
  let base =
        Section
          { secShard = 0
          , secTickStart = 0
          , secTickEnd = 1
          , secEntityMin = 1
          , secEntityMax = 1
          , secPriority = 0
          , secEntities = [ent1]
          , secHash = Hash (BS.replicate 32 0)
          }
      incompatible = base { secTickEnd = 2 }
      outOfRange = base { secEntityMin = 2, secEntityMax = 2 }
      conflict = base { secEntities = [ent1Conflict] }

  case reconcile [incompatible, outOfRange, conflict] of
    Left (ErrIncompatibleRegion _ _) -> return ()
    Left err -> die ("priority mismatch: expected ErrIncompatibleRegion, got " ++ show err)
    Right _ -> die "expected failure for priority order"

secA :: Section
secA =
  Section
    { secShard = 0
    , secTickStart = 0
    , secTickEnd = 1
    , secEntityMin = 1
    , secEntityMax = 1
    , secPriority = 0
    , secEntities = [ent1]
    , secHash = Hash (BS.replicate 32 0)
    }

secB :: Section
secB =
  Section
    { secShard = 0
    , secTickStart = 0
    , secTickEnd = 1
    , secEntityMin = 2
    , secEntityMax = 2
    , secPriority = 0
    , secEntities = [ent2]
    , secHash = Hash (BS.replicate 32 0)
    }

secConflict :: Section
secConflict =
  Section
    { secShard = 0
    , secTickStart = 0
    , secTickEnd = 1
    , secEntityMin = 1
    , secEntityMax = 1
    , secPriority = 0
    , secEntities = [ent1Conflict]
    , secHash = Hash (BS.replicate 32 0)
    }

ent1 :: Entity
ent1 = Entity 1 (BSC.pack "type") (ComponentMap (Map.fromList [(BSC.pack "a", VInt64 1)]))

ent2 :: Entity
ent2 = Entity 2 (BSC.pack "type") (ComponentMap (Map.fromList [(BSC.pack "b", VInt64 2)]))

ent3 :: Entity
ent3 = Entity 3 (BSC.pack "type") (ComponentMap (Map.fromList [(BSC.pack "c", VInt64 3)]))

ent1Conflict :: Entity
ent1Conflict = Entity 1 (BSC.pack "type") (ComponentMap (Map.fromList [(BSC.pack "a", VInt64 9)]))

canonicalizeSnapshot :: Snapshot -> Snapshot
canonicalizeSnapshot snap =
  case encodeSnapshot snap of
    Left _ -> snap
    Right bytes ->
      case decodeSnapshot bytes of
        Left _ -> snap
        Right s -> s

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
