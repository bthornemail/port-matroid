module Main (main) where

import Control.Exception (bracket)
import Network.Socket
import Network.Socket.ByteString (sendAll, recv)
import qualified Data.ByteString.Char8 as C8
import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
  args <- getArgs
  let (sockPath, cmd) = parseArgs args
  when (null cmd) (usage >> exitFailure)
  bracket (connectUnix sockPath) close $ \sock -> do
    sendAll sock (C8.pack (unwords cmd ++ "\n"))
    resp <- recv sock 65536
    C8.putStr resp

parseArgs :: [String] -> (FilePath, [String])
parseArgs args =
  case dropWhile (/= "--control") args of
    (_:p:rest) -> (p, takeCmd args)
    _ -> ("/run/port-matroid/control.sock", takeCmd args)

takeCmd :: [String] -> [String]
takeCmd args =
  case dropWhile (\a -> a /= "--") args of
    (_:rest) -> rest
    [] -> filter (not . ("--" `isPrefixOf`)) args

connectUnix :: FilePath -> IO Socket
connectUnix path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  pure sock

usage :: IO ()
usage = putStrLn "usage: port-matroidctl --control PATH -- command"

when :: Bool -> IO () -> IO ()
when True act = act
when False _ = pure ()

isPrefixOf :: String -> String -> Bool
isPrefixOf pre s = take (length pre) s == pre
