module Snapshot.Scheduler.Decode
  ( decodeWorkSet
  ) where

import Snapshot.Scheduler.Types

import Data.Binary.Get
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Word (Word32, Word64, Word8)

decodeWorkSet :: ByteString -> Either ScheduleError [WorkItem]
decodeWorkSet bs =
  case runGetOrFail parser (BL.fromStrict bs) of
    Left _ -> Left SchErrMalformedWork
    Right (remaining, _, items) ->
      if BL.null remaining then Right items else Left SchErrMalformedWork
  where
    parser = do
      count <- getWord32le
      go count []
    go 0 acc = return (reverse acc)
    go n acc = do
      wid <- getByteString 32
      shard <- getWord32le
      t0 <- getWord64le
      t1 <- getWord64le
      e0 <- getInt64le
      e1 <- getInt64le
      tier <- getWord8
      deadline <- getWord64le
      prio <- getWord32le
      cost <- getWord32le
      instrLen <- getWord32le
      instr <- getByteString (fromIntegral instrLen)
      let cell = Cell shard t0 t1 e0 e1 tier
      let item = WorkItem wid cell deadline prio cost instr
      go (n - 1) (item : acc)
