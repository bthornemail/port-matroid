module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Universe.Core (decodeStream, applyInstructions)
import Snapshot.Universe.Types (AuthorityMask(..), Result(..), HaltReason(..))

import qualified Data.ByteString as BS
import Data.Bits ((.|.), shiftL)
import System.Exit (exitFailure)

main :: IO ()
main = do
  replayCase "test/replay/basic.before.csnp" "test/replay/basic.stream.instrstream" "test/replay/basic.after.csnp"
  putStrLn "Replay vectors: OK"

replayCase :: FilePath -> FilePath -> FilePath -> IO ()
replayCase beforePath streamPath afterPath = do
  beforeBytes <- BS.readFile beforePath
  afterBytes <- BS.readFile afterPath
  streamBytes <- BS.readFile streamPath

  beforeSnap <- case decodeSnapshot beforeBytes of
    Left err -> die ("decode before failed: " ++ show err)
    Right s -> pure s

  instrs <- case decodeStream streamBytes of
    Left err -> die ("decode stream failed: " ++ show err)
    Right xs -> pure xs

  let (res, snap') = applyInstructions beforeSnap fullAuth instrs
  case res of
    Halt r -> die ("replay halted: " ++ show r)
    Next -> do
      out <- case encodeSnapshot snap' of
        Left err -> die ("encode after failed: " ++ show err)
        Right b -> pure b
      if out == afterBytes
        then return ()
        else die ("after snapshot mismatch for " ++ streamPath)

fullAuth :: AuthorityMask
fullAuth = AuthorityMask ((1 `shiftL` 0) .|. (1 `shiftL` 1) .|. (1 `shiftL` 2) .|. (1 `shiftL` 3))

die :: String -> IO a
die msg = do
  putStrLn msg
  exitFailure
