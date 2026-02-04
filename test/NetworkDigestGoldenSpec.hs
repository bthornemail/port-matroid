module Main (main) where

import Snapshot.Scheduler.Network.Encode (encodeMessage)
import Snapshot.Scheduler.Network.Decode (decodeMessage)
import Snapshot.Scheduler.Network.Digest
import Snapshot.Scheduler.Network.Types

import qualified Data.ByteString as BS

main :: IO ()
main = do
  goldenRoundTrip "test/golden-network/digest-basic.msg"
  rejectNonCanonical "test/golden-network/digest-reject-noncanonical.msg"
  putStrLn "OK"

goldenRoundTrip :: FilePath -> IO ()
goldenRoundTrip fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left e -> error ("decodeMessage failed: " ++ show e)
    Right (mt, payload) -> do
      if mt /= MsgWorkDigest then error "wrong message type" else pure ()
      case decodeWorkDigestPayload payload of
        Left e -> error ("decodeWorkDigestPayload failed: " ++ show e)
        Right _ -> do
          let reencoded = encodeMessage MsgWorkDigest payload
          if reencoded /= msg then error "digest message not byte-stable" else pure ()

rejectNonCanonical :: FilePath -> IO ()
rejectNonCanonical fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left _ -> pure ()
    Right (mt, payload) -> do
      if mt /= MsgWorkDigest then error "wrong type for reject case" else pure ()
      case decodeWorkDigestPayload payload of
        Left NetErrNonCanonical -> pure ()
        Left e -> error ("expected NetErrNonCanonical, got: " ++ show e)
        Right _ -> error "non-canonical digest unexpectedly accepted"
