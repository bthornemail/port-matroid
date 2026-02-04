module Runtime.Server
  ( runServer
  ) where

import Runtime.Config
import Runtime.Log (logMsg)
import Runtime.Net.Framing
import Runtime.Node

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception (finally)
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (sendAll)

runServer :: Config -> MVar NodeState -> MVar (Maybe Socket) -> IO ()
runServer cfg stVar sockVar = do
  addr <- resolve (cfgListen cfg)
  sock <- open addr
  logMsg cfg Info ("listening on " ++ cfgListen cfg)
  _ <- swapMVar sockVar (Just sock)
  sem <- newQSem (cfgConnLimit cfg)
  acceptLoop sem sock
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

    acceptLoop sem sock = do
      waitQSem sem
      (conn, _peer) <- accept sock
      _ <- forkIO (handleConn conn `finally` (close conn >> signalQSem sem))
      acceptLoop sem sock

    handleConn conn = do
      setSocketOption conn RecvTimeOut (cfgIdleMs cfg * 1000)
      let loop = do
            eframe <- recvFrame conn (cfgMaxFrame cfg)
            case eframe of
              Left _ -> close conn
              Right frame -> do
                _ <- modifyMVar stVar $ \st -> do
                  res <- handleMessage st frame
                  case res of
                    Left _ -> sendAll conn (BS.pack []) >> pure (st, ())
                    Right st' -> sendAll conn (BS.pack []) >> pure (st', ())
                loop
      loop

splitHostPort :: String -> (String, String)
splitHostPort s =
  case break (== ':') s of
    (h, ':' : p) -> (h, p)
    _ -> ("0.0.0.0", "7000")
