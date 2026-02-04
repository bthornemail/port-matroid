module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Scheduler.Network.Decode (decodeMessage)

import qualified Data.ByteString as BS
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeExtension)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate", path] -> validate path
    _ -> usage >> exitFailure

validate :: FilePath -> IO ()
validate path = do
  bytes <- BS.readFile path
  case takeExtension path of
    ".csnp" ->
      case decodeSnapshot bytes of
        Left err -> die ("snapshot invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".workset" ->
      case decodeWorkSet bytes of
        Left err -> die ("workset invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".ctx" ->
      case decodeRoutingContext bytes of
        Left err -> die ("routing ctx invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".msg" ->
      case decodeMessage bytes of
        Left err -> die ("message invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    _ -> die "unknown extension"

usage :: IO ()
usage = putStrLn "usage: port-matroid-tool validate <file>"

die :: String -> IO ()
die msg = putStrLn msg >> exitFailure
