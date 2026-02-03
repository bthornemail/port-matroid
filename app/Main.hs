module Main (main) where

import Snapshot.Decode (decodeSnapshot, decodeSection)
import Snapshot.Errors (DecodeError(..))

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  args <- getArgs
  ok <- case args of
    [fp] -> runVerify False fp
    ["--quiet", fp] -> runVerify True fp
    _ -> do
      putStrLn "usage: snapshot-verify [--quiet] FILE"
      pure False
  if ok then exitSuccess else exitFailure

runVerify :: Bool -> FilePath -> IO Bool
runVerify quiet fp = do
  bytes <- BS.readFile fp
  case classify bytes of
    Just "CSNP" -> report quiet "CSNP" fp (decodeSnapshot bytes)
    Just "CSPT" -> report quiet "CSPT" fp (decodeSection bytes)
    _ ->
      case decodeSnapshot bytes of
        Right _ -> ok "CSNP"
        Left errSnap ->
          case decodeSection bytes of
            Right _ -> ok "CSPT"
            Left errSec -> do
              failWith quiet fp ("unknown magic; decode failed: CSNP=" ++ show errSnap ++ ", CSPT=" ++ show errSec)
              pure False
  where
    ok kind = do
      if quiet
        then pure ()
        else putStrLn ("OK: " ++ kind ++ " " ++ fp)
      pure True

report :: Bool -> String -> FilePath -> Either DecodeError a -> IO Bool
report quiet kind fp result =
  case result of
    Right _ -> do
      if quiet
        then pure ()
        else putStrLn ("OK: " ++ kind ++ " " ++ fp)
      pure True
    Left err -> do
      failWith quiet fp (show err)
      pure False

failWith :: Bool -> FilePath -> String -> IO ()
failWith quiet fp msg =
  if quiet
    then putStrLn ("ERROR: " ++ fp ++ ": " ++ msg)
    else putStrLn ("ERROR: " ++ fp ++ ": " ++ msg)

classify :: BS.ByteString -> Maybe String
classify bs
  | BS.length bs < 4 = Nothing
  | prefix == "CSNP" = Just "CSNP"
  | prefix == "CSPT" = Just "CSPT"
  | otherwise = Nothing
  where
    prefix = BSC.unpack (BS.take 4 bs)
