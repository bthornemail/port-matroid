module Runtime.Log
  ( logMsg
  ) where

import Runtime.Config

import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

logMsg :: Config -> LogLevel -> String -> IO ()
logMsg cfg level msg =
  if level < cfgLogLevel cfg
    then pure ()
    else do
      ts <- getCurrentTime
      let t = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" ts
      case cfgLogFormat cfg of
        LogText -> putStrLn (t ++ " " ++ show level ++ " " ++ msg)
        LogJson -> putStrLn ("{\"ts\":\"" ++ t ++ "\",\"level\":\"" ++ toLowerStr (show level) ++ "\",\"msg\":\"" ++ escape msg ++ "\"}")
  where
    toLowerStr = map toLower
    toLower c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise = c
    escape [] = []
    escape ('"':xs) = '\\' : '"' : escape xs
    escape ('\\':xs) = '\\' : '\\' : escape xs
    escape (x:xs) = x : escape xs
