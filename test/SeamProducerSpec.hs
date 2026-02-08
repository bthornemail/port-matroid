{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as AT
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Binary.Put (runPut, putInt64le, putWord32le, putWord64le, putWord8, putByteString)
import Data.Int (Int64)
import Data.Word (Word64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.List as List
import System.Exit (exitFailure)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import Data.Time.Clock (getCurrentTime)
import Data.Char (isAlphaNum)

import Snapshot.Types (Snapshot(..), Hash(..))
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Universe.Types (Instruction(..))
import Snapshot.Universe.Core
  ( encodeStream
  , opcodeAdvanceTick
  , opcodeCreateEntity
  , opcodeDeleteEntity
  , opcodeSetComponent
  , opcodeRemoveComponent
  )

import qualified Runtime.Store as Store

main :: IO ()
main = do
  dir <- mkTempDir
  res <- run dir
  removeDirectoryRecursive dir
  case res of
    Right () -> putStrLn "seam-producer: OK"
    Left err -> putStrLn err >> exitFailure

run :: FilePath -> IO (Either String ())
run dir = do
  createDirectoryIfMissing True dir
  initRes <- initStore dir
  case initRes of
    Left e -> pure (Left e)
    Right () -> do
      bytes <- BS.readFile "test/seam/automaton/events.ndjson"
      let ls = filter (not . BL.null) (BL.split 10 (BL.fromStrict bytes))
      instrEs <- traverse decodeEnvelopeLine ls
      case sequence instrEs of
        Left e -> pure (Left e)
        Right instrs ->
          case encodeStream instrs of
            Left e -> pure (Left ("encodeStream failed: " ++ show e))
            Right stream -> do
              ar <- Store.appendWal dir stream
              case ar of
                Left e -> pure (Left ("appendWal failed: " ++ e))
                Right () -> do
                  snap0E <- Store.loadSnapshot dir
                  case snap0E of
                    Left e -> pure (Left ("loadSnapshot failed: " ++ e))
                    Right snap0 -> do
                      snap1E <- Store.replayWalWith False dir snap0
                      case snap1E of
                        Left e -> pure (Left ("replayWal failed: " ++ e))
                        Right snap1 -> do
                          want <- BSC.readFile "test/seam/automaton/expected.hash"
                          got <- snapshotHashHex snap1
                          if BSC.filter (/= '\n') want == got
                            then pure (Right ())
                            else pure (Left ("snapshot hash mismatch: expected " ++ BSC.unpack want ++ " got " ++ BSC.unpack got))

mkTempDir :: IO FilePath
mkTempDir = do
  base <- getTemporaryDirectory
  pid <- getProcessID
  now <- getCurrentTime
  let stamp = filter isAlphaNum (show now)
  pure (base </> ("port-matroid-seam-producer-" ++ show pid ++ "-" ++ stamp))

initStore :: FilePath -> IO (Either String ())
initStore dir = do
  -- Create a new store in a fresh temp dir. This is idempotent for the test.
  Store.rotateSnapshotAndWal dir emptySnapshot

emptySnapshot :: Snapshot
emptySnapshot = Snapshot 0 [] (Hash (BS.replicate 32 0))

snapshotHashHex :: Snapshot -> IO BS.ByteString
snapshotHashHex s =
  case encodeSnapshot s of
    Left err -> pure (BSC.pack ("encodeSnapshot failed: " ++ show err))
    Right bytes -> do
      if BS.length bytes < 32
        then pure ""
        else pure (toHex (SHA.hash (BS.take (BS.length bytes - 32) bytes)))

-- minimal hex encoder
toHex :: BS.ByteString -> BS.ByteString
toHex bs = BS.concatMap byteToHex bs
  where
    byteToHex w =
      let hi = w `div` 16
          lo = w `mod` 16
      in BS.pack [hexNibble hi, hexNibble lo]
    hexNibble n
      | n < 10 = 48 + n
      | otherwise = 87 + n

-- Envelope decoding (schema-stable, minimal)

decodeEnvelopeLine :: BL.ByteString -> IO (Either String Instruction)
decodeEnvelopeLine line =
  case A.eitherDecode line of
    Left err -> pure (Left ("envelope decode failed: " ++ err))
    Right v ->
      case AT.parseEither parseEnvelope v of
        Left err -> pure (Left ("envelope parse failed: " ++ err))
        Right i -> pure (Right i)

parseEnvelope :: A.Value -> AT.Parser Instruction
parseEnvelope = A.withObject "EventEnvelope" $ \o -> do
  -- Mirror the port-matroid-tool fail-closed schema checks.
  let required = List.sort ["namespace", "authority", "meta", "payload"]
  if keyList o /= required then fail "envelope schema mismatch" else pure ()
  _ns <- o A..: "namespace" :: AT.Parser T.Text
  authV <- o A..: "authority" :: AT.Parser A.Value
  kind <- parseAuthority authV
  if kind /= "direct" then fail "authority.kind must be direct for Producer" else pure ()
  metaV <- o A..: "meta" :: AT.Parser A.Value
  _ <- parseMeta metaV
  payload <- o A..: "payload" :: AT.Parser A.Value
  parsePayload payload

keyList :: A.Object -> [T.Text]
keyList o = List.sort (map K.toText (KM.keys o))

parseAuthority :: A.Value -> AT.Parser T.Text
parseAuthority = A.withObject "Authority" $ \a -> do
  let required = List.sort ["kind", "basis"]
  if keyList a /= required then fail "authority schema mismatch" else pure ()
  a A..: "kind" :: AT.Parser T.Text

parseMeta :: A.Value -> AT.Parser ()
parseMeta = A.withObject "EnvelopeMeta" $ \m -> do
  let required = List.sort ["writer", "epoch", "gen"]
  if keyList m /= required then fail "meta schema mismatch" else pure ()
  _ <- (m A..: "writer" :: AT.Parser T.Text)
  _ <- (m A..: "epoch" :: AT.Parser Word64)
  _ <- (m A..: "gen" :: AT.Parser Word64)
  pure ()

parsePayload :: A.Value -> AT.Parser Instruction
parsePayload = A.withObject "payload" $ \p -> do
  op <- p A..: "op" :: AT.Parser T.Text
  case op of
    "advance_tick" -> do
      requireKeys p ["op","delta"]
      delta <- p A..: "delta" :: AT.Parser Word64
      let payloadBytes = BL.toStrict $ runPut (putWord64le delta)
      pure (Instruction opcodeAdvanceTick 0 payloadBytes)
    "create_entity" -> do
      requireKeys p ["op","eid","etype","owner_mask"]
      eid <- p A..: "eid" :: AT.Parser Int64
      etype <- p A..: "etype" :: AT.Parser T.Text
      owner <- p A..: "owner_mask" :: AT.Parser Word64
      let tyBytes = TE.encodeUtf8 etype
      let payloadBytes = BL.toStrict $ runPut $ do
            putInt64le eid
            putWord32le (fromIntegral (BS.length tyBytes))
            putByteString tyBytes
            putWord64le owner
      pure (Instruction opcodeCreateEntity 0 payloadBytes)
    "set_component_string" -> do
      requireKeys p ["op","eid","key","value"]
      eid <- p A..: "eid" :: AT.Parser Int64
      key <- p A..: "key" :: AT.Parser T.Text
      val <- p A..: "value" :: AT.Parser T.Text
      let keyBytes = TE.encodeUtf8 key
      let valBytes = TE.encodeUtf8 val
      let payloadBytes = BL.toStrict $ runPut $ do
            putInt64le eid
            putWord32le (fromIntegral (BS.length keyBytes))
            putByteString keyBytes
            putWord8 0x05
            putWord32le (fromIntegral (BS.length valBytes))
            putByteString valBytes
      pure (Instruction opcodeSetComponent 0 payloadBytes)
    "remove_component" -> do
      requireKeys p ["op","eid","key"]
      eid <- p A..: "eid" :: AT.Parser Int64
      key <- p A..: "key" :: AT.Parser T.Text
      let keyBytes = TE.encodeUtf8 key
      let payloadBytes = BL.toStrict $ runPut $ do
            putInt64le eid
            putWord32le (fromIntegral (BS.length keyBytes))
            putByteString keyBytes
      pure (Instruction opcodeRemoveComponent 0 payloadBytes)
    "delete_entity" -> do
      requireKeys p ["op","eid"]
      eid <- p A..: "eid" :: AT.Parser Int64
      let payloadBytes = BL.toStrict $ runPut (putInt64le eid)
      pure (Instruction opcodeDeleteEntity 0 payloadBytes)
    _ -> fail "unknown op"

requireKeys :: A.Object -> [T.Text] -> AT.Parser ()
requireKeys o requiredList = do
  let required = List.sort requiredList
  if keyList o /= required then fail "payload schema mismatch" else pure ()
