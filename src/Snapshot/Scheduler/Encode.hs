module Snapshot.Scheduler.Encode
  ( encodeWorkSet
  ) where

import Snapshot.Scheduler.Types

import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

encodeWorkSet :: [WorkItem] -> Either ScheduleError ByteString
encodeWorkSet items = do
  mapM_ ensureWorkId items
  return $ BL.toStrict $ runPut $ do
    putWord32le (fromIntegral (length items))
    mapM_ putItem items
  where
    putItem it = do
      let wid = workId it
      putByteString wid
      let c = workCell it
      putWord32le (cellShard c)
      putWord64le (cellT0 c)
      putWord64le (cellT1 c)
      putInt64le (cellE0 c)
      putInt64le (cellE1 c)
      putWord8 (cellTier c)
      putWord64le (workDeadline it)
      putWord32le (workPriority it)
      putWord32le (workCost it)
      let instr = workInstrStream it
      putWord32le (fromIntegral (BS.length instr))
      putByteString instr

    ensureWorkId it =
      if BS.length (workId it) == 32
        then Right ()
        else Left SchErrMalformedWork
