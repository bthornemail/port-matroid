module Main (main) where

import Runtime.Config
import Runtime.Log (logMsg)
import Runtime.Store
import Runtime.Node
import Runtime.Server
import Runtime.Control

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Types (RoutingContext)
import qualified Snapshot.Types as Snapshot.Types

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import qualified Data.ByteString as BS
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Posix.Signals (installHandler, Handler(Catch), sigTERM, sigINT)

main :: IO ()
main = do
  args <- getArgs
  cfg <- loadConfigOrExit (configPath args)
  rctx <- loadRoutingOrExit (cfgDataDir cfg </> "routing.ctx")
  snap <- loadSnapshotOrExit (cfgDataDir cfg)
  snap' <- replayOrExit (cfgDataDir cfg) snap
  let node = initNode cfg rctx snap'
  stVar <- newMVar node
  _ <- forkIO (runServer cfg stVar)
  _ <- forkIO (runControl cfg stVar)
  _ <- installHandler sigTERM (Catch (shutdown cfg)) Nothing
  _ <- installHandler sigINT (Catch (shutdown cfg)) Nothing
  loop cfg stVar

loop :: Config -> MVar NodeState -> IO ()
loop cfg stVar = do
  threadDelay (cfgTickMs cfg * 1000)
  _ <- modifyMVar stVar $ \st -> do
    res <- tickOnce st
    case res of
      Left err -> do
        logMsg cfg Error ("tick failed: " ++ err)
        exitFailure
      Right st' -> pure (st', ())
  loop cfg stVar

shutdown :: Config -> IO ()
shutdown cfg = do
  logMsg cfg Info "shutdown"
  exitFailure

configPath :: [String] -> FilePath
configPath args =
  case dropWhile (/= "--config") args of
    (_:p:_) -> p
    _ -> "/etc/port-matroid/port-matroid.conf"

loadConfigOrExit :: FilePath -> IO Config
loadConfigOrExit path = do
  cfg <- loadConfig path
  case cfg of
    Left err -> do
      putStrLn ("config error: " ++ err)
      exitFailure
    Right c -> pure c

loadRoutingOrExit :: FilePath -> IO RoutingContext
loadRoutingOrExit path = do
  bytes <- BS.readFile path
  case decodeRoutingContext bytes of
    Left err -> do
      putStrLn ("routing context error: " ++ show err)
      exitFailure
    Right ctx -> pure ctx

loadSnapshotOrExit :: FilePath -> IO Snapshot.Types.Snapshot
loadSnapshotOrExit dir = do
  snap <- loadSnapshot dir
  case snap of
    Left err -> do
      putStrLn ("snapshot error: " ++ err)
      exitFailure
    Right s -> pure s

replayOrExit :: FilePath -> Snapshot.Types.Snapshot -> IO Snapshot.Types.Snapshot
replayOrExit dir snap = do
  res <- replayWal dir snap
  case res of
    Left err -> do
      putStrLn ("wal error: " ++ err)
      exitFailure
    Right s -> pure s
