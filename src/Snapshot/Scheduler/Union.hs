module Snapshot.Scheduler.Union
  ( unionWorkSets
  ) where

import Snapshot.Scheduler.Types

import qualified Data.Map.Strict as Map

unionWorkSets :: [WorkItem] -> [WorkItem] -> Either ScheduleError CanonicalWorkSet
unionWorkSets a b =
  case foldl insert (Right Map.empty) (a ++ b) of
    Left err -> Left err
    Right mp -> Right (canonicalizeWorkSet (Map.elems mp))
  where
    insert acc w =
      case acc of
        Left err -> Left err
        Right m ->
          case Map.lookup (workId w) m of
            Nothing -> Right (Map.insert (workId w) w m)
            Just w' ->
              if w' == w
                then Right m
                else Left SchErrMalformedWork
