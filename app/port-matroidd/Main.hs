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
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.Posix.Signals (installHandler, Handler(Catch), sigTERM, sigINT)
import Network.Socket (Socket, close)
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
  sockVar <- newMVar Nothing
  _ <- forkIO (runServer cfg stVar sockVar)
  _ <- forkIO (runControl cfg stVar)
  _ <- installHandler sigTERM (Catch (signalShutdown shutdownFlag)) Nothing
  _ <- installHandler sigINT (Catch (signalShutdown shutdownFlag)) Nothing
  loop cfg stVar shutdownFlag sockVar

loop :: Config -> MVar NodeState -> IO ()
loop cfg stVar shutdownFlag sockVar = do
  threadDelay (cfgTickMs cfg * 1000)
  stop <- readMVar shutdownFlag
  if stop
    then gracefulShutdown cfg stVar sockVar
    else do
      res <- modifyMVar stVar $ \st -> do
        r <- tickOnce st
        case r of
          Left err -> pure (st, Left err)
          Right st' -> pure (st', Right ())
      case res of
        Left err -> do
          logMsg cfg Error ("tick failed: " ++ err)
          gracefulShutdown cfg stVar sockVar
        Right () -> loop cfg stVar shutdownFlag sockVar

signalShutdown :: MVar Bool -> IO ()
signalShutdown flag = do
  _ <- swapMVar flag True
  pure ()

gracefulShutdown :: Config -> MVar NodeState -> MVar (Maybe Socket) -> IO ()
gracefulShutdown cfg stVar sockVar = do
  msock <- readMVar sockVar
  case msock of
    Nothing -> pure ()
    Just s -> close s
  st <- readMVar stVar
  res <- Runtime.Store.rotateSnapshotAndWal (cfgDataDir cfg) (nodeSnapshot st)
  case res of
    Left err -> do
      logMsg cfg Error ("shutdown failed: " ++ err)
      exitFailure
    Right () -> do
      logMsg cfg Info "shutdown complete"
      exitSuccess

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
