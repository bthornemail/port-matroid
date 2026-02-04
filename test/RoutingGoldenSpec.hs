module Main (main) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Encode (encodeRoutingContext)
import Snapshot.Routing.Core (routeShard)

import qualified Data.ByteString as BS

main :: IO ()
main = do
  ctxBytes <- BS.readFile "test/golden-routing/basic.ctx"
  case decodeRoutingContext ctxBytes of
    Left err -> error ("decodeRoutingContext failed: " ++ show err)
    Right ctx -> do
      case encodeRoutingContext ctx of
        Left err -> error ("encodeRoutingContext failed: " ++ show err)
        Right encoded ->
          if encoded /= ctxBytes
            then error "routing context roundtrip mismatch"
            else do
              expected <- BS.readFile "test/golden-routing/basic.route"
              case routeShard ctx 42 of
                Left err -> error ("routeShard failed: " ++ show err)
                Right peers ->
                  if BS.concat peers /= expected
                    then error "routeShard output mismatch"
                    else putStrLn "OK"
