module Main (main) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Types (RoutingError(..))

import qualified Data.ByteString as BS

main :: IO ()
main = do
  let cases =
        [ ("test/bad-routing/bad-version.ctx", RoutErrBadVersion)
        , ("test/bad-routing/bad-params.ctx", RoutErrInvalidParams)
        , ("test/bad-routing/unsorted-peers.ctx", RoutErrInvalidPeerSet)
        , ("test/bad-routing/duplicate-peer.ctx", RoutErrInvalidPeerSet)
        , ("test/bad-routing/bad-salt-length.ctx", RoutErrMalformed)
        , ("test/bad-routing/truncated.ctx", RoutErrMalformed)
        , ("test/bad-routing/trailing-garbage.ctx", RoutErrMalformed)
        ]
  mapM_ runCase cases
  putStrLn "OK"

runCase :: (FilePath, RoutingError) -> IO ()
runCase (path, expected) = do
  bytes <- BS.readFile path
  case decodeRoutingContext bytes of
    Left err ->
      if err == expected
        then pure ()
        else error ("routing bad case mismatch: " ++ path ++ " got " ++ show err)
    Right _ -> error ("routing bad case unexpectedly succeeded: " ++ path)
