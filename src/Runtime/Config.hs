module Runtime.Config
  ( Config(..)
  , LogFormat(..)
  , LogLevel(..)
  , defaultConfig
  , loadConfig
  ) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import System.Directory (doesFileExist)

data LogFormat = LogText | LogJson
  deriving (Eq, Show)

data LogLevel = Debug | Info | Warn | Error
  deriving (Eq, Show, Ord)

data Config = Config
  { cfgDataDir :: FilePath
  , cfgListen :: String
  , cfgControl :: FilePath
  , cfgMaxFrame :: Int
  , cfgTickMs :: Int
  , cfgIdleMs :: Int
  , cfgConnLimit :: Int
  , cfgWalTruncate :: Bool
  , cfgLogFormat :: LogFormat
  , cfgLogLevel :: LogLevel
  , cfgReadonly :: Bool
  } deriving (Eq, Show)

defaultConfig :: Config
defaultConfig = Config
  { cfgDataDir = "/var/lib/port-matroid"
  , cfgListen = "0.0.0.0:7000"
  , cfgControl = "/run/port-matroid/control.sock"
  , cfgMaxFrame = 1048576
  , cfgTickMs = 250
  , cfgIdleMs = 5000
  , cfgConnLimit = 256
  , cfgWalTruncate = False
  , cfgLogFormat = LogJson
  , cfgLogLevel = Info
  , cfgReadonly = False
  }

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("config file missing: " ++ path))
    else do
      contents <- BS.readFile path
      let ls = filter (not . null) (map strip (lines (toString contents)))
      pure (foldl apply (Right defaultConfig) ls)
  where
    toString = map (toEnum . fromEnum) . BS.unpack
    strip s = trim (takeWhile (/= '#') s)
    trim = f . f
      where f = reverse . dropWhile isSpace

    apply acc line =
      case acc of
        Left err -> Left err
        Right cfg ->
          case break (== '=') line of
            (k, '=':v) -> setKey cfg (trim k) (trim v)
            _ -> Left ("invalid config line: " ++ line)

    setKey cfg k v =
      case k of
        "data_dir" -> Right cfg { cfgDataDir = v }
        "listen" -> Right cfg { cfgListen = v }
        "control_socket" -> Right cfg { cfgControl = v }
        "max_frame_bytes" -> readInt v >>= \n -> Right cfg { cfgMaxFrame = n }
        "tick_ms" -> readInt v >>= \n -> Right cfg { cfgTickMs = n }
        "idle_ms" -> readInt v >>= \n -> Right cfg { cfgIdleMs = n }
        "conn_limit" -> readInt v >>= \n -> Right cfg { cfgConnLimit = n }
        "wal_truncate" -> parseBool v >>= \b -> Right cfg { cfgWalTruncate = b }
        "log_format" -> parseFormat v >>= \f -> Right cfg { cfgLogFormat = f }
        "log_level" -> parseLevel v >>= \l -> Right cfg { cfgLogLevel = l }
        "readonly" -> parseBool v >>= \b -> Right cfg { cfgReadonly = b }
        _ -> Left ("unknown key: " ++ k)

    readInt s =
      case reads s of
        [(n, "")] -> Right n
        _ -> Left ("invalid int: " ++ s)

    parseFormat s =
      case s of
        "text" -> Right LogText
        "json" -> Right LogJson
        _ -> Left ("invalid log_format: " ++ s)

    parseLevel s =
      case s of
        "debug" -> Right Debug
        "info" -> Right Info
        "warn" -> Right Warn
        "error" -> Right Error
        _ -> Left ("invalid log_level: " ++ s)

    parseBool s =
      case s of
        "true" -> Right True
        "false" -> Right False
        _ -> Left ("invalid bool: " ++ s)
