module Runtime.Net.Framing
  ( recvFrame
  , sendFrame
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Binary.Get
import Data.Binary.Put
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)

recvFrame :: Socket -> Int -> IO (Either String BS.ByteString)
recvFrame sock maxBytes = do
  hdr <- recvExact sock 4
  case hdr of
    Nothing -> pure (Left "eof")
    Just h ->
      case runGetOrFail getWord32le (BL.fromStrict h) of
        Left _ -> pure (Left "bad length header")
        Right (_, _, len) -> do
          let n = fromIntegral len
          if n > maxBytes
            then pure (Left "frame too large")
            else do
              body <- recvExact sock n
              case body of
                Nothing -> pure (Left "eof")
                Just b -> pure (Right b)

sendFrame :: Socket -> BS.ByteString -> IO ()
sendFrame sock payload = do
  let hdr = BL.toStrict $ runPut (putWord32le (fromIntegral (BS.length payload)))
  sendAll sock hdr
  sendAll sock payload

recvExact :: Socket -> Int -> IO (Maybe BS.ByteString)
recvExact sock n = go n []
  where
    go 0 acc = pure (Just (BS.concat (reverse acc)))
    go k acc = do
      chunk <- recv sock k
      if BS.null chunk
        then pure Nothing
        else go (k - BS.length chunk) (chunk:acc)
