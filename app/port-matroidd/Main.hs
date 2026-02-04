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
import qualified Runtime.Store

main :: IO ()
main = do
  args <- getArgs
  cfg <- loadConfigOrExit (configPath args)
  rctx <- loadRoutingOrExit (cfgDataDir cfg </> "routing.ctx")
  snap <- loadSnapshotOrExit (cfgDataDir cfg)
  snap' <- replayOrExit (cfgDataDir cfg) snap
  let node = initNode cfg rctx snap'
  stVar <- newMVar node
  shutdownFlag <- newMVar False
  _ <- forkIO (runServer cfg stVar)
  _ <- forkIO (runControl cfg stVar)
  _ <- installHandler sigTERM (Catch (signalShutdown shutdownFlag)) Nothing
  _ <- installHandler sigINT (Catch (signalShutdown shutdownFlag)) Nothing
  loop cfg stVar shutdownFlag

loop :: Config -> MVar NodeState -> IO ()
loop cfg stVar shutdownFlag = do
  threadDelay (cfgTickMs cfg * 1000)
  stop <- readMVar shutdownFlag
  if stop
    then gracefulShutdown cfg stVar
    else do
      _ <- modifyMVar stVar $ \st -> do
        res <- tickOnce st
        case res of
          Left err -> do
            logMsg cfg Error ("tick failed: " ++ err)
            exitFailure
          Right st' -> pure (st', ())
      loop cfg stVar shutdownFlag

signalShutdown :: MVar Bool -> IO ()
signalShutdown flag = do
  _ <- swapMVar flag True
  pure ()

gracefulShutdown :: Config -> MVar NodeState -> IO ()
gracefulShutdown cfg stVar = do
  st <- readMVar stVar
  _ <- Runtime.Store.rotateSnapshotAndWal (cfgDataDir cfg) (nodeSnapshot st)
  logMsg cfg Info "shutdown complete"
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
