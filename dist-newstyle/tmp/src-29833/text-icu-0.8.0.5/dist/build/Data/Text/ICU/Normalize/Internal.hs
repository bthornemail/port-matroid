{-# LINE 1 "Data/Text/ICU/Normalize/Internal.hsc" #-}
{-# LANGUAGE CPP, DeriveDataTypeable, ForeignFunctionInterface #-}
-- |
-- Module      : Data.Text.ICU.Normalize.Internal
-- Copyright   : (c) 2010 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC

module Data.Text.ICU.Normalize.Internal
    (
      UNormalizationCheckResult
    , toNCR
    ) where



import Foreign.C.Types (CInt)

type UNormalizationCheckResult = CInt

toNCR :: UNormalizationCheckResult -> Maybe Bool
toNCR (0)    = Just False
{-# LINE 25 "Data/Text/ICU/Normalize/Internal.hsc" #-}
toNCR (2) = Nothing
{-# LINE 26 "Data/Text/ICU/Normalize/Internal.hsc" #-}
toNCR (1)   = Just True
{-# LINE 27 "Data/Text/ICU/Normalize/Internal.hsc" #-}
toNCR _                    = error "toNormalizationCheckResult"
