{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Runtime.Net.Gossip.Types
  ( NodeId(..)
  , Summary(..)
  , Msg(..)
  , Nack(..)
  , NackCode(..)
  , encodeMsg
  , decodeMsg
  ) where

import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word16, Word32, Word64, Word8)
import GHC.Generics (Generic)

newtype NodeId = NodeId Word32
  deriving (Eq, Ord, Show)

data Summary = Summary
  { sNodeId :: !NodeId
  , sEpoch :: !Word64
  , sGen :: !Word32
  , sSnapHash :: !ByteString -- 32 bytes
  , sWalBytes :: !Word64
  , sWalVersion :: !Word16
  }
  deriving (Eq, Show, Generic)

data NackCode
  = BadMsg
  | BadOffset
  | TooLarge
  | VersionMismatch
  | HashMismatch
  | NotFound
  deriving (Eq, Show)

data Nack = Nack
  { nCode :: !NackCode
  , nInfo :: !ByteString
  }
  deriving (Eq, Show)

data Msg
  = MHello !Summary
  | MPullReq
      { prWantGen :: !Word32
      , prWantHash :: !ByteString
      , prFromOff :: !Word64
      , prMaxBytes :: !Word32
      }
  | MPullSnap
      { psGen :: !Word32
      , psSnapHash :: !ByteString
      , psBytes :: !ByteString
      }
  | MPullWal
      { pwGen :: !Word32
      , pwSnapHash :: !ByteString
      , pwOffset :: !Word64
      , pwBytes :: !ByteString
      }
  | MNack !Nack
  deriving (Eq, Show)

tagHello, tagPullReq, tagPullSnap, tagPullWal, tagNack :: Word8
tagHello = 0x01
tagPullReq = 0x02
tagPullSnap = 0x03
tagPullWal = 0x04
tagNack = 0x7F

putHash32 :: ByteString -> Put
putHash32 h =
  if BL.length (BL.fromStrict h) /= 32
    then error "hash32 length"
    else putByteString h

getHash32 :: Get ByteString
getHash32 = getByteString 32

putNodeId :: NodeId -> Put
putNodeId (NodeId w) = putWord32le w

getNodeId :: Get NodeId
getNodeId = NodeId <$> getWord32le

putNackCode :: NackCode -> Put
putNackCode = putWord16le . \case
  BadMsg -> 1
  BadOffset -> 2
  TooLarge -> 3
  VersionMismatch -> 4
  HashMismatch -> 5
  NotFound -> 6

getNackCode :: Get NackCode
getNackCode = do
  w <- getWord16le
  pure $ case w of
    1 -> BadMsg
    2 -> BadOffset
    3 -> TooLarge
    4 -> VersionMismatch
    5 -> HashMismatch
    6 -> NotFound
    _ -> BadMsg

encodeMsg :: Msg -> ByteString
encodeMsg m = BL.toStrict $ runPut $ case m of
  MHello Summary{..} -> do
    putWord8 tagHello
    putNodeId sNodeId
    putWord64le sEpoch
    putWord32le sGen
    putHash32 sSnapHash
    putWord64le sWalBytes
    putWord16le sWalVersion
  MPullReq{..} -> do
    putWord8 tagPullReq
    putWord32le prWantGen
    putHash32 prWantHash
    putWord64le prFromOff
    putWord32le prMaxBytes
  MPullSnap{..} -> do
    putWord8 tagPullSnap
    putWord32le psGen
    putHash32 psSnapHash
    putByteString psBytes
  MPullWal{..} -> do
    putWord8 tagPullWal
    putWord32le pwGen
    putHash32 pwSnapHash
    putWord64le pwOffset
    putByteString pwBytes
  MNack (Nack c info) -> do
    putWord8 tagNack
    putNackCode c
    putByteString info

decodeMsg :: ByteString -> Either String Msg
decodeMsg bs =
  case runGetOrFail getMsg (BL.fromStrict bs) of
    Left (_, _, e) -> Left e
    Right (_, _, m) -> Right m
  where
    getMsg = do
      tag <- getWord8
      case tag of
        0x01 -> do
          nid <- getNodeId
          ep <- getWord64le
          g <- getWord32le
          h <- getHash32
          wb <- getWord64le
          ver <- getWord16le
          pure $ MHello (Summary nid ep g h wb ver)
        0x02 -> do
          g <- getWord32le
          h <- getHash32
          off <- getWord64le
          mx <- getWord32le
          pure $ MPullReq g h off mx
        0x03 -> do
          g <- getWord32le
          h <- getHash32
          rest <- getRemainingLazyByteString
          pure $ MPullSnap g h (BL.toStrict rest)
        0x04 -> do
          g <- getWord32le
          h <- getHash32
          off <- getWord64le
          rest <- getRemainingLazyByteString
          pure $ MPullWal g h off (BL.toStrict rest)
        0x7F -> do
          c <- getNackCode
          rest <- getRemainingLazyByteString
          pure $ MNack (Nack c (BL.toStrict rest))
        _ -> pure $ MNack (Nack BadMsg (BSC.pack "unknown tag"))
