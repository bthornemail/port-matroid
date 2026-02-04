module Runtime.Server
  ( runServer
  ) where

import Runtime.Config
import Runtime.Log (logMsg)
import Runtime.Net.Framing
import Runtime.Node

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (sendAll)

runServer :: Config -> MVar NodeState -> IO ()
runServer cfg stVar = do
  addr <- resolve (cfgListen cfg)
  sock <- open addr
  logMsg cfg Info ("listening on " ++ cfgListen cfg)
  acceptLoop sock
  where
    resolve addr = do
      let (host, port) = splitHostPort addr
      let hints = defaultHints { addrSocketType = Stream }
      head <$> getAddrInfo (Just hints) (Just host) (Just port)

    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock (addrAddress addr)
      listen sock 128
      pure sock

    acceptLoop sock = do
      (conn, _peer) <- accept sock
      _ <- forkIO (handleConn conn)
      acceptLoop sock

    handleConn conn = do
      eframe <- recvFrame conn (cfgMaxFrame cfg)
      case eframe of
        Left _ -> close conn
        Right frame -> do
          st <- readMVar stVar
          res <- handleMessage st frame
          case res of
            Left _ -> sendAll conn (BS.pack [])
            Right st' -> do
              _ <- swapMVar stVar st'
              sendAll conn (BS.pack [])
          close conn

splitHostPort :: String -> (String, String)
splitHostPort s =
  case break (== ':') s of
    (h, ':' : p) -> (h, p)
    _ -> ("0.0.0.0", "7000")
