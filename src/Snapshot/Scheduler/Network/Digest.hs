module Snapshot.Scheduler.Network.Digest
  ( CanonicalDigest(..)
  , digestEntries
  , buildWorkDigestPayload
  , decodeWorkDigestPayload
  ) where

import Snapshot.Scheduler.Network.Types
import Snapshot.Scheduler.Types (WorkItem(..), Cell(..))

import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (sortBy)
import Data.Word (Word32, Word64, Word8)

cmpCell :: Cell -> Cell -> Ordering
cmpCell (Cell sa t0a t1a e0a e1a ta) (Cell sb t0b t1b e0b e1b tb) =
  compare (sa, t0a, t1a, e0a, e1a, ta) (sb, t0b, t1b, e0b, e1b, tb)

cmpItem :: (Cell, ByteString) -> (Cell, ByteString) -> Ordering
cmpItem (c1, w1) (c2, w2) =
  case cmpCell c1 c2 of
    EQ -> compare w1 w2
    o -> o

newtype CanonicalDigest = CanonicalDigest [(Cell, ByteString)]
  deriving (Eq, Show)

digestEntries :: CanonicalDigest -> [(Cell, ByteString)]
digestEntries (CanonicalDigest xs) = xs

buildWorkDigestPayload :: Word32 -> [WorkItem] -> Either NetError (CanonicalDigest, ByteString)
buildWorkDigestPayload shard items = do
  let pairs = [ (workCell w, workId w) | w <- items, cellShard (workCell w) == shard ]
  let canon = sortBy cmpItem pairs
  if any (\(_, wid) -> BS.length wid /= 32) canon
    then Left NetErrMalformed
    else
      let payload = BL.toStrict $ runPut $ do
            putWord32le shard
            putWord32le (fromIntegral (length canon))
            mapM_ putOne canon
      in Right (CanonicalDigest canon, payload)
  where
    putOne (c, wid) = do
      putByteString wid
      let (sh, t0, t1, e0, e1, tier) = encodeCell c
      putWord32le sh
      putWord64le t0
      putWord64le t1
      putInt64le e0
      putInt64le e1
      putWord8 tier

decodeWorkDigestPayload :: ByteString -> Either NetError (Word32, CanonicalDigest)
decodeWorkDigestPayload bs =
  case runGetOrFail getAll (BL.fromStrict bs) of
    Left _ -> Left NetErrMalformed
    Right (rest, _, v) ->
      if BL.null rest then validate v else Left NetErrMalformed
  where
    getAll = do
      shard <- getWord32le
      count <- getWord32le
      xs <- sequence (replicate (fromIntegral count) getOne)
      return (shard, xs)
    getOne = do
      wid <- getByteString 32
      sh <- getWord32le
      t0 <- getWord64le
      t1 <- getWord64le
      e0 <- getInt64le
      e1 <- getInt64le
      tier <- getWord8
      return (decodeCell (sh, t0, t1, e0, e1, tier), wid)
    validate (shard, xs) =
      let canon = sortBy cmpItem xs
      in if canon == xs
           then Right (shard, CanonicalDigest xs)
           else Left NetErrNonCanonical
