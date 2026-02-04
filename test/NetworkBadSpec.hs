module Main (main) where

import Snapshot.Scheduler.Network.Decode (decodeMessage)
import Snapshot.Scheduler.Network.Digest (decodeWorkDigestPayload)
import Snapshot.Scheduler.Network.Types (MessageType(..), NetError(..))

import qualified Data.ByteString as BS

main :: IO ()
main = do
  expectMalformed "test/bad-network/truncated-header.msg"
  expectDigestMalformed "test/bad-network/digest-truncated.msg"
  expectUnknown "test/bad-network/unknown-type.msg"
  expectNonCanonical "test/golden-network/digest-reject-noncanonical.msg"
  putStrLn "OK"

expectMalformed :: FilePath -> IO ()
expectMalformed fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left NetErrMalformed -> pure ()
    Left e -> error ("expected NetErrMalformed, got: " ++ show e)
    Right _ -> error ("expected malformed decode failure: " ++ fp)

expectUnknown :: FilePath -> IO ()
expectUnknown fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left NetErrMalformed -> pure ()
    Left e -> error ("expected NetErrMalformed for unknown type, got: " ++ show e)
    Right _ -> error ("expected unknown type decode failure: " ++ fp)

expectNonCanonical :: FilePath -> IO ()
expectNonCanonical fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left e -> error ("expected message decode, got: " ++ show e)
    Right (mt, payload) -> do
      if mt /= MsgWorkDigest then error "wrong message type for non-canonical test" else pure ()
      case decodeWorkDigestPayload payload of
        Left NetErrNonCanonical -> pure ()
        Left e -> error ("expected NetErrNonCanonical, got: " ++ show e)
        Right _ -> error "non-canonical digest unexpectedly accepted"

expectDigestMalformed :: FilePath -> IO ()
expectDigestMalformed fp = do
  msg <- BS.readFile fp
  case decodeMessage msg of
    Left e -> error ("expected message decode, got: " ++ show e)
    Right (mt, payload) -> do
      if mt /= MsgWorkDigest then error "wrong message type for digest truncated test" else pure ()
      case decodeWorkDigestPayload payload of
        Left NetErrMalformed -> pure ()
        Left e -> error ("expected NetErrMalformed, got: " ++ show e)
        Right _ -> error "truncated digest unexpectedly accepted"
