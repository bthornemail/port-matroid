module Snapshot.Scheduler.Types
  ( Cell(..)
  , WorkItem(..)
  , CanonicalWorkSet(..)
  , canonicalizeWorkSet
  , unCanonicalWorkSet
  , workKey
  , compareWorkItem
  , SchedulerParams(..)
  , SchedulerState(..)
  , ScheduleError(..)
  , defaultParams
  , defaultState
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Word (Word32, Word64, Word8)
import qualified Data.List as List

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

newtype CanonicalWorkSet = CanonicalWorkSet [WorkItem]
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

workKey :: WorkItem -> (Word8, Word32, Word64, Word32, ByteString)
workKey w =
  ( cellTier (workCell w)
  , negate32 (workPriority w)
  , workDeadline w
  , workCost w
  , workId w
  )

compareWorkItem :: WorkItem -> WorkItem -> Ordering
compareWorkItem a b = compare (workKey a, workId a) (workKey b, workId b)

canonicalizeWorkSet :: [WorkItem] -> CanonicalWorkSet
canonicalizeWorkSet = CanonicalWorkSet . List.sortBy compareWorkItem

unCanonicalWorkSet :: CanonicalWorkSet -> [WorkItem]
unCanonicalWorkSet (CanonicalWorkSet ws) = ws

negate32 :: Word32 -> Word32
negate32 w = maxBound - w
