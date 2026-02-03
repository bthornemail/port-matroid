{-# LANGUAGE CPP #-}
{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -Wno-missing-safe-haskell-mode #-}
module Paths_port_matroid (
    version,
    getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir,
    getDataFileName, getSysconfDir
  ) where

import qualified Control.Exception as Exception
import Data.Version (Version(..))
import System.Environment (getEnv)
import Prelude

#if defined(VERSION_base)

#if MIN_VERSION_base(4,0,0)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#else
catchIO :: IO a -> (Exception.Exception -> IO a) -> IO a
#endif

#else
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#endif
catchIO = Exception.catch

version :: Version
version = Version [0,1,0,0] []
bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath

bindir     = "/root/.cabal/bin"
libdir     = "/root/.cabal/lib/x86_64-linux-ghc-9.0.2/port-matroid-0.1.0.0-inplace-golden"
dynlibdir  = "/root/.cabal/lib/x86_64-linux-ghc-9.0.2"
datadir    = "/root/.cabal/share/x86_64-linux-ghc-9.0.2/port-matroid-0.1.0.0"
libexecdir = "/root/.cabal/libexec/x86_64-linux-ghc-9.0.2/port-matroid-0.1.0.0"
sysconfdir = "/root/.cabal/etc"

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath
getBinDir = catchIO (getEnv "port_matroid_bindir") (\_ -> return bindir)
getLibDir = catchIO (getEnv "port_matroid_libdir") (\_ -> return libdir)
getDynLibDir = catchIO (getEnv "port_matroid_dynlibdir") (\_ -> return dynlibdir)
getDataDir = catchIO (getEnv "port_matroid_datadir") (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "port_matroid_libexecdir") (\_ -> return libexecdir)
getSysconfDir = catchIO (getEnv "port_matroid_sysconfdir") (\_ -> return sysconfdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "/" ++ name)
