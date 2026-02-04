module Main (main) where

import Snapshot.Scheduler.Types (ScheduleError(..))

import qualified Data.ByteString as BS
import Data.Bits ((.&.), shiftR)
import System.Exit (exitFailure)

main :: IO ()
main = do
  golden "test/golden-scheduler-errors/limit.err" SchErrLimitExceeded
  golden "test/golden-scheduler-errors/invalid-cell.err" SchErrInvalidCell
  golden "test/golden-scheduler-errors/out-of-range.err" SchErrOutOfRange
  golden "test/golden-scheduler-errors/duplicate-workid.err" SchErrDuplicateWorkId
  golden "test/golden-scheduler-errors/malformed.err" SchErrMalformedWork
  golden "test/golden-scheduler-errors/internal.err" SchErrInternal
  putStrLn "Scheduler error golden: OK"

golden :: FilePath -> ScheduleError -> IO ()
golden fp reason = do
  bytes <- BS.readFile fp
  if bytes == codeBytes reason
    then return ()
    else die ("scheduler code mismatch: " ++ fp)

codeBytes :: ScheduleError -> BS.ByteString
codeBytes r =
  let w = reasonCode r
  in BS.pack [fromIntegral (w .&. 0xff), fromIntegral (w `shiftR` 8)]

reasonCode :: ScheduleError -> Int
reasonCode r =
  case r of
    SchErrLimitExceeded -> 0x0001
    SchErrInvalidCell -> 0x0002
    SchErrOutOfRange -> 0x0003
    SchErrDuplicateWorkId -> 0x0004
    SchErrMalformedWork -> 0x0005
    SchErrInternal -> 0x0006

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
