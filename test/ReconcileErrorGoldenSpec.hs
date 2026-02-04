module Main (main) where

import Snapshot.Reconcile.Types (ReconcileError(..), Region(..))

import qualified Data.ByteString as BS
import Data.Bits ((.&.), shiftR)
import System.Exit (exitFailure)

main :: IO ()
main = do
  golden "test/golden-reconcile/overlap-mismatch.err" (ErrOverlapMismatch 1)
  golden "test/golden-reconcile/non-covering.err" (ErrNonCovering [])
  golden "test/golden-reconcile/out-of-range.err" (ErrOutOfRange 1 dummyRegion)
  golden "test/golden-reconcile/incompatible-region.err" (ErrIncompatibleRegion dummyRegion dummyRegion)
  golden "test/golden-reconcile/internal.err" (ErrInternalInvariant dummyRegion dummyRegion)
  putStrLn "Reconcile error golden: OK"

golden :: FilePath -> ReconcileError -> IO ()
golden fp reason = do
  bytes <- BS.readFile fp
  if bytes == codeBytes reason
    then return ()
    else die ("reconcile code mismatch: " ++ fp)

codeBytes :: ReconcileError -> BS.ByteString
codeBytes r =
  let w = reasonCode r
  in BS.pack [fromIntegral (w .&. 0xff), fromIntegral (w `shiftR` 8)]

reasonCode :: ReconcileError -> Int
reasonCode r =
  case r of
    ErrOverlapMismatch _ -> 0x0001
    ErrNonCovering _ -> 0x0002
    ErrOutOfRange _ _ -> 0x0003
    ErrIncompatibleRegion _ _ -> 0x0004
    ErrInternalInvariant _ _ -> 0x0005

dummyRegion :: Region
dummyRegion = Region 0 0 1 0 0 0

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
