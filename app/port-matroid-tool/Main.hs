{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Snapshot.Decode (decodeSnapshot)
import Snapshot.Scheduler.Decode (decodeWorkSet)
import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Scheduler.Network.Decode (decodeMessage)
import qualified Runtime.Store

import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as AT
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Binary.Put (runPut, putInt64le, putWord32le, putWord64le, putWord8, putByteString)
import Data.Int (Int64)
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeExtension)
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import Text.Read (readMaybe)

import Snapshot.Types (Snapshot(..), Hash(..))
import qualified Snapshot.Types as ST
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
import Data.ByteString.Char8 (pack)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["validate", path] -> validate path
    ["audit", dir] -> audit dir
    ["append-envelope", dir, ndjson] -> appendEnvelope dir ndjson
    ["verify-envelope-digest-index", dir] -> verifyEnvelopeDigestIndex dir
    ["verify-envelope-digest-prefix", dir, nStr] -> verifyEnvelopeDigestPrefix dir nStr
    ["rebuild-envelope-digest-index", dir] -> rebuildEnvelopeDigestIndex dir
    ["provenance-index", dir, out] -> writeProvenanceIndex dir out
    ["verify-provenance-index", dir, out] -> verifyProvenanceIndex dir out
    ["export-snapshot-json", path] -> exportSnapshotJson path
    ["replay-hash", dir] -> replayHash dir
    _ -> usage >> exitFailure

validate :: FilePath -> IO ()
validate path = do
  bytes <- BS.readFile path
  case takeExtension path of
    ".csnp" ->
      case decodeSnapshot bytes of
        Left err -> die ("snapshot invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".workset" ->
      case decodeWorkSet bytes of
        Left err -> die ("workset invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".ctx" ->
      case decodeRoutingContext bytes of
        Left err -> die ("routing ctx invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    ".msg" ->
      case decodeMessage bytes of
        Left err -> die ("message invalid: " ++ show err)
        Right _ -> putStrLn "ok"
    _ -> die "unknown extension"

usage :: IO ()
usage =
  putStrLn $
    "usage: port-matroid-tool validate <file>\n"
      ++ "  | audit <data-dir>\n"
      ++ "  | append-envelope <data-dir> <events.ndjson>\n"
      ++ "  | verify-envelope-digest-index <data-dir>\n"
      ++ "  | verify-envelope-digest-prefix <data-dir> <n-lines>\n"
      ++ "  | rebuild-envelope-digest-index <data-dir>\n"
      ++ "  | provenance-index <data-dir> <out.tsv>\n"
      ++ "  | verify-provenance-index <data-dir> <out.tsv>\n"
      ++ "  | export-snapshot-json <file.csnp>\n"
      ++ "  | replay-hash <data-dir>"

die :: String -> IO a
die msg = putStrLn msg >> exitFailure

replayHash :: FilePath -> IO ()
replayHash dir = do
  snap0E <- Runtime.Store.loadSnapshot dir
  case snap0E of
    Left e -> die ("loadSnapshot failed: " ++ e)
    Right snap0 -> do
      snap1E <- Runtime.Store.replayWalWith False dir snap0
      case snap1E of
        Left e -> die ("wal replay error: " ++ e)
        Right snap1 -> do
          h <- snapshotHashHex snap1
          BS.putStr h
          BS.putStr "\n"

snapshotHashHex :: Snapshot -> IO BS.ByteString
snapshotHashHex s =
  case encodeSnapshot s of
    Left err -> pure (pack ("encodeSnapshot failed: " ++ show err))
    Right bytes ->
      if BS.length bytes < 32
        then pure ""
        else pure (toHex (SHA.hash (BS.take (BS.length bytes - 32) bytes)))

exportSnapshotJson :: FilePath -> IO ()
exportSnapshotJson path = do
  bytes <- BS.readFile path
  case decodeSnapshot bytes of
    Left err -> die ("snapshot invalid: " ++ show err)
    Right snap -> BL.putStr (A.encode (snapshotToJson snap) <> "\n")

snapshotToJson :: Snapshot -> A.Value
snapshotToJson (Snapshot tick ents (Hash h)) =
  A.object
    [ "tick" A..= tick
    , "hash_hex" A..= hexText h
    , "entity_count" A..= length ents
    , "entities" A..= map entityToJson ents
    ]

entityToJson :: ST.Entity -> A.Value
entityToJson (ST.Entity eid ty (ST.ComponentMap mp)) =
  A.object
    [ "eid" A..= eid
    , "etype" A..= TE.decodeUtf8 ty
    , "components" A..= A.object (map componentPair (Map.toAscList mp))
    ]
  where
    componentPair (k, v) = (K.fromText (TE.decodeUtf8 k), valueToJson v)

-- Encode values in a JS-safe way (no float ambiguity, no int precision loss).
valueToJson :: ST.Value -> A.Value
valueToJson v =
  case v of
    ST.VInt64 n ->
      A.object ["t" A..= ("i64" :: T.Text), "v" A..= T.pack (show n)]
    ST.VUInt64 n ->
      A.object ["t" A..= ("u64" :: T.Text), "v" A..= T.pack (show n)]
    ST.VFloat32 w ->
      A.object ["t" A..= ("f32_bits" :: T.Text), "v" A..= T.pack (show w)]
    ST.VFloat64 w ->
      A.object ["t" A..= ("f64_bits" :: T.Text), "v" A..= T.pack (show w)]
    ST.VString s ->
      A.object ["t" A..= ("string" :: T.Text), "v" A..= TE.decodeUtf8 s]
    ST.VBool b ->
      A.object ["t" A..= ("bool" :: T.Text), "v" A..= b]
    ST.VNull ->
      A.object ["t" A..= ("null" :: T.Text)]

hexText :: BS.ByteString -> T.Text
hexText = TE.decodeUtf8 . toHex

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

appendEnvelope :: FilePath -> FilePath -> IO ()
appendEnvelope dir ndjson = do
  -- Initialize store if needed; keep this idempotent.
  createDirectoryIfMissing True dir
  m <- Runtime.Store.readManifest dir
  case m of
    Right _ -> pure ()
    Left _ -> do
      r <- Runtime.Store.rotateSnapshotAndWal dir emptySnapshot
      case r of
        Left e -> die ("init store failed: " ++ e)
        Right () -> pure ()
  bytes <- BS.readFile ndjson
  let bytesNl =
        if BS.null bytes
          then bytes
          else if BS.last bytes == 10 then bytes else BS.snoc bytes 10
  let ls = filter (not . BL.null) (BL.split 10 (BL.fromStrict bytes))
  -- Envelope-level dedupe: reject re-appending identical envelope lines.
  -- Digest meaning: sha256(raw_line_bytes_without_newline) hex.
  let digests = map (toHex . SHA.hash . BL.toStrict) ls
  existing <- loadEnvelopeDigestIndex dir
  -- We intentionally do NOT reject duplicates within the same append call:
  -- identical envelopes can be semantically meaningful as repeated occurrences.
  -- The safety property we enforce is idempotence across appends to the same store.
  case firstAlreadyAppended existing digests of
    Just d -> die ("duplicate envelope digest (already appended): " ++ T.unpack (TE.decodeUtf8 d))
    Nothing -> pure ()
  let instrEs = map decodeEnvelopeLine ls
  instrs <- case sequence instrEs of
    Left e -> die e
    Right is -> pure is
  case encodeStream instrs of
    Left err -> die ("encode stream failed: " ++ show err)
    Right stream -> do
      r <- Runtime.Store.appendWal dir stream
      case r of
        Left e -> die ("append wal failed: " ++ e)
        Right () -> do
          persistEnvelopeDigestIndex dir digests
          -- Persist the raw envelope bytes for audit/debug and for digest-index rebuild.
          persistEnvelopeLog dir bytesNl
          putStrLn "ok"

emptySnapshot :: Snapshot
emptySnapshot = Snapshot 0 [] (Hash (BS.replicate 32 0))

decodeEnvelopeLine :: BL.ByteString -> Either String Instruction
decodeEnvelopeLine line = do
  v <- A.eitherDecode line
  AT.parseEither parseEnvelope v

parseEnvelope :: A.Value -> AT.Parser Instruction
parseEnvelope = A.withObject "EventEnvelope" $ \o -> do
  -- Fail-closed envelope schema: exact key set (order independent).
  let keys = keyList o
  let required = List.sort ["namespace", "authority", "meta", "payload"]
  if keys /= required then fail "envelope schema mismatch (unexpected/missing keys)" else pure ()
  ns <- o A..: "namespace" :: AT.Parser T.Text
  producer <- parseNamespaceProducer ns
  auth <- o A..: "authority" :: AT.Parser A.Value
  kind <- parseAuthority auth
  if kind /= "direct" then fail "authority.kind must be direct for Producer" else pure ()
  metaV <- o A..: "meta" :: AT.Parser A.Value
  _ <- parseMeta metaV
  payload <- o A..: "payload" :: AT.Parser A.Value
  parsePayload producer payload

keyList :: A.Object -> [T.Text]
keyList o = List.sort (map K.toText (KM.keys o))

parseAuthority :: A.Value -> AT.Parser T.Text
parseAuthority = A.withObject "Authority" $ \a -> do
  -- Authority must match the seam contract and remain schema-stable.
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

parsePayload :: T.Text -> A.Value -> AT.Parser Instruction
parsePayload producer = A.withObject "payload" $ \p -> do
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
      requireComponentPrefix producer key
      val <- p A..: "value" :: AT.Parser T.Text
      let keyBytes = TE.encodeUtf8 key
      let valBytes = TE.encodeUtf8 val
      let payloadBytes = BL.toStrict $ runPut $ do
            putInt64le eid
            putWord32le (fromIntegral (BS.length keyBytes))
            putByteString keyBytes
            putWord8 0x05 -- VString
            putWord32le (fromIntegral (BS.length valBytes))
            putByteString valBytes
      pure (Instruction opcodeSetComponent 0 payloadBytes)
    "remove_component" -> do
      requireKeys p ["op","eid","key"]
      eid <- p A..: "eid" :: AT.Parser Int64
      key <- p A..: "key" :: AT.Parser T.Text
      requireComponentPrefix producer key
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

-- Namespace format: ulp.trace.<producer>.<rest>.vN
parseNamespaceProducer :: T.Text -> AT.Parser T.Text
parseNamespaceProducer ns =
  case T.splitOn "." ns of
    ("ulp":"trace":producer:rest) ->
      case reverse rest of
        (v:_) | T.isPrefixOf "v" v && T.length v >= 2 -> pure producer
        _ -> fail "namespace invalid"
    _ -> fail "namespace invalid"

requireComponentPrefix :: T.Text -> T.Text -> AT.Parser ()
requireComponentPrefix producer key = do
  let prefix = producer <> "__"
  if prefix `T.isPrefixOf` key
    then pure ()
    else fail "component key missing/wrong producer prefix"

requireKeys :: A.Object -> [T.Text] -> AT.Parser ()
requireKeys o requiredList = do
  let required = List.sort requiredList
  if keyList o /= required then fail "payload schema mismatch" else pure ()

-- Envelope digest index helpers
digestIndexPath :: FilePath -> FilePath
digestIndexPath dir = dir </> "envelope-digests.sha256"

envelopeLogPath :: FilePath -> FilePath
envelopeLogPath dir = dir </> "envelopes.ndjson"

loadEnvelopeDigestIndex :: FilePath -> IO (Set.Set BS.ByteString)
loadEnvelopeDigestIndex dir = do
  let p = digestIndexPath dir
  ex <- doesFileExist p
  if not ex
    then pure Set.empty
    else do
      content <- BS.readFile p
      let ds = filter (not . BS.null) (BS.split 10 content)
      pure (Set.fromList ds)

persistEnvelopeDigestIndex :: FilePath -> [BS.ByteString] -> IO ()
persistEnvelopeDigestIndex dir ds = do
  let p = digestIndexPath dir
  let nl = BS.singleton 10
  let bytes = BS.concat (map (<> nl) ds)
  BS.appendFile p bytes

persistEnvelopeLog :: FilePath -> BS.ByteString -> IO ()
persistEnvelopeLog dir bytes = do
  let p = envelopeLogPath dir
  BS.appendFile p bytes

firstAlreadyAppended :: Set.Set BS.ByteString -> [BS.ByteString] -> Maybe BS.ByteString
firstAlreadyAppended existing = go
  where
    go [] = Nothing
    go (d:ds) = if Set.member d existing then Just d else go ds

verifyEnvelopeDigestIndex :: FilePath -> IO ()
verifyEnvelopeDigestIndex dir = do
  let idxP = digestIndexPath dir
  let logP = envelopeLogPath dir
  exIdx <- doesFileExist idxP
  exLog <- doesFileExist logP
  if not exIdx
    then die "digest index missing (envelope-digests.sha256)"
    else pure ()
  if not exLog
    then die "envelope log missing (envelopes.ndjson); cannot verify/rebuild index"
    else pure ()
  idx <- BS.readFile idxP
  logB <- BS.readFile logP
  let idxDs = filter (not . BS.null) (BS.split 10 idx)
  let logLs = filter (not . BL.null) (BL.split 10 (BL.fromStrict logB))
  let want = map (toHex . SHA.hash . BL.toStrict) logLs
  if length idxDs /= length want
    then die ("digest index count mismatch: index=" ++ show (length idxDs) ++ " envelopes=" ++ show (length want))
    else
      case firstMismatch 1 idxDs want of
        Just (n, got, w) ->
          die
            ( "digest index mismatch at line "
                ++ show n
                ++ ": index="
                ++ T.unpack (TE.decodeUtf8 got)
                ++ " envelopes="
                ++ T.unpack (TE.decodeUtf8 w)
            )
        Nothing -> putStrLn ("ok digest index (" ++ show (length want) ++ " envelopes)")

verifyEnvelopeDigestPrefix :: FilePath -> String -> IO ()
verifyEnvelopeDigestPrefix dir nStr =
  case readMaybe nStr :: Maybe Int of
    Nothing -> die "n-lines must be an integer"
    Just n | n < 0 -> die "n-lines must be >= 0"
    Just n -> do
      let idxP = digestIndexPath dir
      let logP = envelopeLogPath dir
      exIdx <- doesFileExist idxP
      exLog <- doesFileExist logP
      if not exIdx
        then die "digest index missing (envelope-digests.sha256)"
        else pure ()
      if not exLog
        then die "envelope log missing (envelopes.ndjson); cannot verify prefix"
        else pure ()
      idx <- BS.readFile idxP
      logB <- BS.readFile logP
      let idxDs0 = filter (not . BS.null) (BS.split 10 idx)
      let logLs0 = filter (not . BL.null) (BL.split 10 (BL.fromStrict logB))
      let want0 = map (toHex . SHA.hash . BL.toStrict) logLs0
      let n' = min n (min (length idxDs0) (length want0))
      let idxDs = take n' idxDs0
      let want = take n' want0
      case firstMismatch 1 idxDs want of
        Just (ln, got, w) ->
          die
            ( "digest index prefix mismatch at line "
                ++ show ln
                ++ ": index="
                ++ T.unpack (TE.decodeUtf8 got)
                ++ " envelopes="
                ++ T.unpack (TE.decodeUtf8 w)
            )
        Nothing -> putStrLn ("ok digest index prefix (" ++ show n' ++ " envelopes)")

rebuildEnvelopeDigestIndex :: FilePath -> IO ()
rebuildEnvelopeDigestIndex dir = do
  let logP = envelopeLogPath dir
  exLog <- doesFileExist logP
  if not exLog
    then die "envelope log missing (envelopes.ndjson); cannot rebuild index"
    else pure ()
  logB <- BS.readFile logP
  let logLs = filter (not . BL.null) (BL.split 10 (BL.fromStrict logB))
  let ds = map (toHex . SHA.hash . BL.toStrict) logLs
  let p = digestIndexPath dir
  let nl = BS.singleton 10
  BS.writeFile p (BS.concat (map (<> nl) ds))
  putStrLn ("ok rebuilt digest index (" ++ show (length ds) ++ " envelopes)")

writeProvenanceIndex :: FilePath -> FilePath -> IO ()
writeProvenanceIndex dir out = do
  let logP = envelopeLogPath dir
  exLog <- doesFileExist logP
  if not exLog
    then die "envelope log missing (envelopes.ndjson); cannot build provenance index"
    else pure ()
  logB <- BS.readFile logP
  let logLs = filter (not . BL.null) (BL.split 10 (BL.fromStrict logB))
  let rows = zip [1 :: Int ..] logLs
  let header = BS.intercalate (BS.singleton 9) ["line", "envelope_digest", "namespace", "writer", "epoch", "gen", "op", "key"] <> BS.singleton 10
  let outLines = map provenanceRow rows
  BS.writeFile out (BS.concat (header : outLines))
  putStrLn "ok provenance index"

verifyProvenanceIndex :: FilePath -> FilePath -> IO ()
verifyProvenanceIndex dir out = do
  ex <- doesFileExist out
  if not ex then die "provenance index file missing" else pure ()
  existing <- BS.readFile out
  -- Recompute expected and compare bytes exactly (deterministic contract).
  let logP = envelopeLogPath dir
  exLog <- doesFileExist logP
  if not exLog
    then die "envelope log missing (envelopes.ndjson); cannot verify provenance index"
    else pure ()
  logB <- BS.readFile logP
  let logLs = filter (not . BL.null) (BL.split 10 (BL.fromStrict logB))
  let rows = zip [1 :: Int ..] logLs
  let header = BS.intercalate (BS.singleton 9) ["line", "envelope_digest", "namespace", "writer", "epoch", "gen", "op", "key"] <> BS.singleton 10
  let expected = BS.concat (header : map provenanceRow rows)
  if existing /= expected
    then die "provenance index mismatch (file differs from recomputed)"
    else putStrLn "ok provenance index"

provenanceRow :: (Int, BL.ByteString) -> BS.ByteString
provenanceRow (ln, line) =
  case A.eitherDecode line of
    Left _err -> pack (show ln ++ "\t<decode_error>\t\t\t\t\t\t\n")
    Right v ->
      case AT.parseEither parseEnvelopeInfo v of
        Left err -> pack (show ln ++ "\t<parse_error:" ++ err ++ ">\t\t\t\t\t\t\n")
        Right (ns, writer, epoch, gen, op, mKey) ->
          let digest = toHex (SHA.hash (BL.toStrict line))
              fields =
                [ pack (show ln)
                , digest
                , TE.encodeUtf8 ns
                , TE.encodeUtf8 writer
                , pack (show epoch)
                , pack (show gen)
                , TE.encodeUtf8 op
                , maybe "" TE.encodeUtf8 mKey
                ]
          in BS.intercalate (BS.singleton 9) fields <> BS.singleton 10

parseEnvelopeInfo :: A.Value -> AT.Parser (T.Text, T.Text, Word64, Word64, T.Text, Maybe T.Text)
parseEnvelopeInfo = A.withObject "EventEnvelope" $ \o -> do
  -- Reuse the same fail-closed envelope schema here too.
  let keys = keyList o
  let required = List.sort ["namespace", "authority", "meta", "payload"]
  if keys /= required then fail "envelope schema mismatch" else pure ()
  ns <- o A..: "namespace" :: AT.Parser T.Text
  _auth <- o A..: "authority" :: AT.Parser A.Value
  metaV <- o A..: "meta" :: AT.Parser A.Value
  (writer, epoch, gen) <- parseMetaInfo metaV
  payload <- o A..: "payload" :: AT.Parser A.Value
  (op, mKey) <- parsePayloadInfo payload
  pure (ns, writer, epoch, gen, op, mKey)

parseMetaInfo :: A.Value -> AT.Parser (T.Text, Word64, Word64)
parseMetaInfo = A.withObject "EnvelopeMeta" $ \m -> do
  let required = List.sort ["writer", "epoch", "gen"]
  if keyList m /= required then fail "meta schema mismatch" else pure ()
  w <- (m A..: "writer" :: AT.Parser T.Text)
  e <- (m A..: "epoch" :: AT.Parser Word64)
  g <- (m A..: "gen" :: AT.Parser Word64)
  pure (w, e, g)

parsePayloadInfo :: A.Value -> AT.Parser (T.Text, Maybe T.Text)
parsePayloadInfo = A.withObject "payload" $ \p -> do
  op <- p A..: "op" :: AT.Parser T.Text
  case op of
    "set_component_string" -> do
      key <- p A..: "key" :: AT.Parser T.Text
      pure (op, Just key)
    "remove_component" -> do
      key <- p A..: "key" :: AT.Parser T.Text
      pure (op, Just key)
    _ -> pure (op, Nothing)

firstMismatch :: Int -> [BS.ByteString] -> [BS.ByteString] -> Maybe (Int, BS.ByteString, BS.ByteString)
firstMismatch _ [] [] = Nothing
firstMismatch n (a:as) (b:bs) =
  if a == b then firstMismatch (n + 1) as bs else Just (n, a, b)
firstMismatch _ _ _ = Just (0, "", "")

audit :: FilePath -> IO ()
audit dir = do
  m <- Runtime.Store.readManifest dir
  let (gen, crcStatus) =
        case m of
          Right mf -> (Just (Runtime.Store.manifestGeneration mf), "ok")
          Left _ -> (Nothing, "missing")
  snap <- Runtime.Store.loadSnapshot dir
  case snap of
    Left err -> die ("snapshot error: " ++ err)
    Right s -> do
      res <- Runtime.Store.replayWalWith False dir s
      case res of
        Left err -> die ("wal replay error: " ++ err)
        Right _ -> do
          cnt <- Runtime.Store.walEntryCount dir
          case cnt of
            Left err -> die ("wal count error: " ++ err)
            Right n ->
              case gen of
                Just g -> putStrLn ("ok gen=" ++ show g ++ " wal_entries=" ++ show n ++ " wal_version=" ++ show Runtime.Store.walVersion ++ " manifest_crc=" ++ crcStatus)
                Nothing -> putStrLn ("ok wal_entries=" ++ show n ++ " wal_version=" ++ show Runtime.Store.walVersion ++ " manifest_crc=" ++ crcStatus)
