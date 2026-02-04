module Runtime.Control
  ( runControl
  ) where

import Runtime.Config
import Runtime.Log (logMsg)
import Runtime.Node
import Runtime.Store (writeSnapshot)
import Runtime.Net.Framing

import Snapshot.Types (Snapshot)
import Snapshot.Routing.Types (routingEpoch)
import qualified Snapshot.Encode as Snapshot.Encode

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Network.Socket
import System.Directory (removeFile, doesFileExist)

runControl :: Config -> MVar NodeState -> IO ()
runControl cfg stVar = do
  cleanup (cfgControl cfg)
  sock <- socket AF_UNIX Stream defaultProtocol
  bind sock (SockAddrUnix (cfgControl cfg))
  listen sock 32
  logMsg cfg Info ("control socket on " ++ cfgControl cfg)
  acceptLoop sock
  where
    cleanup path = do
      exists <- doesFileExist path
      if exists then removeFile path else pure ()

    acceptLoop sock = do
      (conn, _) <- accept sock
      _ <- forkIO (handleConn conn)
      acceptLoop sock

    handleConn conn = do
      eframe <- recvFrame conn (cfgMaxFrame cfg)
      case eframe of
        Left _ -> close conn
        Right msg -> do
          resp <- handleCmd (C8.unpack (C8.takeWhile (/= '\n') msg))
          sendFrame conn (C8.pack resp)
          close conn

    handleCmd cmd = do
      st <- readMVar stVar
      case words cmd of
        ["status"] ->
          pure ("ok epoch=" ++ show (routingEpoch (nodeRouting st)) ++ "\n")
        ["dump-snapshot", path] -> do
          case encodeSnapshotBytes (nodeSnapshot st) of
            Left err -> pure ("error " ++ err ++ "\n")
            Right bytes -> BS.writeFile path bytes >> pure "ok\n"
        ["dump-snapshot"] -> do
          case encodeSnapshotBytes (nodeSnapshot st) of
            Left err -> pure ("error " ++ err ++ "\n")
            Right bytes -> pure (C8.unpack bytes ++ "\n")
        _ -> pure "error unknown\n"

encodeSnapshotBytes :: Snapshot -> Either String BS.ByteString
encodeSnapshotBytes snap =
  case Snapshot.Encode.encodeSnapshot snap of
    Left err -> Left (show err)
    Right bytes -> Right bytes
