{-# LANGUAGE CPP #-}
{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -Wno-missing-safe-haskell-mode #-}
module Paths_text_icu (
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
version = Version [0,8,0,5] []
bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath

bindir     = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/bin"
libdir     = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/lib"
dynlibdir  = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/lib"
datadir    = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/share"
libexecdir = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/libexec"
sysconfdir = "/root/.cabal/store/ghc-9.0.2/text-icu-0.8.0.5-cc9d2add16b02c2099205c47a0cc375d259807bc07de0648de5c41260d9c75a8/etc"

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath
getBinDir = catchIO (getEnv "text_icu_bindir") (\_ -> return bindir)
getLibDir = catchIO (getEnv "text_icu_libdir") (\_ -> return libdir)
getDynLibDir = catchIO (getEnv "text_icu_dynlibdir") (\_ -> return dynlibdir)
getDataDir = catchIO (getEnv "text_icu_datadir") (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "text_icu_libexecdir") (\_ -> return libexecdir)
getSysconfDir = catchIO (getEnv "text_icu_sysconfdir") (\_ -> return sysconfdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "/" ++ name)
