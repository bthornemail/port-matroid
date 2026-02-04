module Snapshot.Scheduler.Types
  ( Cell(..)
  , WorkItem(..)
  , SchedulerParams(..)
  , SchedulerState(..)
  , ScheduleError(..)
  , defaultParams
  , defaultState
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Word (Word32, Word64, Word8)

data Cell = Cell
  { cellShard :: !Word32
  , cellT0 :: !Word64
  , cellT1 :: !Word64
  , cellE0 :: !Int64
  , cellE1 :: !Int64
  , cellTier :: !Word8
  }
  deriving (Eq, Ord, Show)

data WorkItem = WorkItem
  { workId :: !ByteString
  , workCell :: !Cell
  , workDeadline :: !Word64
  , workPriority :: !Word32
  , workCost :: !Word32
  , workInstrStream :: !ByteString
  }
  deriving (Eq, Show)

data SchedulerParams = SchedulerParams
  { sliceBudget :: !Word32
  , maxSkip :: !Word32
  , maxWork :: !Word32
  }
  deriving (Eq, Show)

data SchedulerState = SchedulerState
  { cursorCell :: !(Maybe Cell)
  }
  deriving (Eq, Show)

data ScheduleError
  = SchErrLimitExceeded
  | SchErrInvalidCell
  | SchErrOutOfRange
  | SchErrDuplicateWorkId
  | SchErrMalformedWork
  | SchErrInternal
  deriving (Eq, Show)

defaultParams :: SchedulerParams
defaultParams = SchedulerParams
  { sliceBudget = 1000
  , maxSkip = 1000
  , maxWork = 100000
  }

defaultState :: SchedulerState
defaultState = SchedulerState { cursorCell = Nothing }
