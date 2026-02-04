module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Scheduler.Network.Decode (decodeMessage)
import qualified Runtime.Store

import qualified Data.ByteString as BS
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeExtension)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate", path] -> validate path
    ["audit", dir] -> audit dir
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
usage = putStrLn "usage: port-matroid-tool validate <file> | audit <data-dir>"

die :: String -> IO ()
die msg = putStrLn msg >> exitFailure

audit :: FilePath -> IO ()
audit dir = do
  m <- Runtime.Store.readManifest dir
  gen <- case m of
    Right mf -> pure (Just (Runtime.Store.manifestGeneration mf))
    Left _ -> pure Nothing
  snap <- Runtime.Store.loadSnapshot dir
  case snap of
    Left err -> die ("snapshot error: " ++ err)
    Right s -> do
      res <- Runtime.Store.replayWal dir s
      case res of
        Left err -> die ("wal replay error: " ++ err)
        Right _ -> do
          cnt <- Runtime.Store.walEntryCount dir
          case cnt of
            Left err -> die ("wal count error: " ++ err)
            Right n ->
              case gen of
                Just g -> putStrLn ("ok gen=" ++ show g ++ " wal_entries=" ++ show n)
                Nothing -> putStrLn ("ok wal_entries=" ++ show n)
