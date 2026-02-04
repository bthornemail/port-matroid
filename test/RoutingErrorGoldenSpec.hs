module Main (main) where

import Snapshot.Routing.Types

import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

main :: IO ()
main = do
  let cases =
        [ (RoutErrBadVersion, "bad-version")
        , (RoutErrInvalidParams, "invalid-params")
        , (RoutErrInvalidPeerSet, "invalid-peerset")
        , (RoutErrInvalidPeerId, "invalid-peerid")
        , (RoutErrMalformed, "malformed")
        ]
  mapM_ checkCase cases
  putStrLn "OK"

checkCase :: (RoutingError, FilePath) -> IO ()
checkCase (err, name) = do
  let file = "test/golden-routing-errors/" ++ name ++ ".err"
  bytes <- BS.readFile file
  if bytes /= encodeErr err
    then error ("routing error encoding mismatch: " ++ name)
    else do
      case decodeErr bytes of
        Nothing -> error ("routing error decoding failed: " ++ name)
        Just err' ->
          if err' /= err
            then error ("routing error roundtrip mismatch: " ++ name)
            else pure ()

encodeErr :: RoutingError -> BS.ByteString
encodeErr err =
  BL.toStrict $ runPut $ putWord16le (routingErrorToCode err)

decodeErr :: BS.ByteString -> Maybe RoutingError
decodeErr bs =
  case runGetOrFail getWord16le (BL.fromStrict bs) of
    Left _ -> Nothing
    Right (rest, _, code) ->
      if BL.null rest
        then codeToRoutingError code
        else Nothing
