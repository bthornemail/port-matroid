module Snapshot.Reconcile.Core
  ( reconcile
  ) where

import Snapshot.Types
import Snapshot.Encode (encodeSnapshot)
import Snapshot.Decode (decodeSnapshot)
import Snapshot.Reconcile.Types (Region(..), ReconcileError(..))

import Control.Monad (when)
import Data.Int (Int64)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map

reconcile :: [Section] -> Either ReconcileError Snapshot
reconcile [] = Left (ErrNonCovering [])
reconcile secs@(s0:_) = do
  let base = regionOf s0
  mapM_ (ensureCompatible base) secs
  entityMap <- foldl combine (Right Map.empty) secs
  let ents = Map.elems entityMap
      tick = secTickStart s0
      snap0 = Snapshot tick ents (Hash (BS.replicate 32 0))
  case encodeSnapshot snap0 of
    Left _ -> Left (ErrInternalInvariant base base)
    Right bytes ->
      case decodeSnapshot bytes of
        Left _ -> Left (ErrInternalInvariant base base)
        Right snap -> Right snap
  where
    combine acc sec = do
      mp <- acc
      foldl (insertEntity (regionOf sec)) (Right mp) (secEntities sec)

ensureCompatible :: Region -> Section -> Either ReconcileError ()
ensureCompatible base sec = do
  let r = regionOf sec
  when (regShard r /= regShard base
     || regTickStart r /= regTickStart base
     || regTickEnd r /= regTickEnd base
     || regPriority r /= regPriority base) $
    Left (ErrIncompatibleRegion base r)
  mapM_ (checkRange r) (secEntities sec)

checkRange :: Region -> Entity -> Either ReconcileError ()
checkRange r e
  | entId e < regEntityMin r || entId e > regEntityMax r =
      Left (ErrOutOfRange (entId e) r)
  | otherwise = Right ()

insertEntity :: Region -> Either ReconcileError (Map.Map Int64 Entity) -> Entity -> Either ReconcileError (Map.Map Int64 Entity)
insertEntity _ (Left err) _ = Left err
insertEntity _ (Right mp) e =
  case Map.lookup (entId e) mp of
    Nothing -> Right (Map.insert (entId e) e mp)
    Just existing ->
      if existing == e
        then Right mp
        else Left (ErrOverlapMismatch (entId e))

regionOf :: Section -> Region
regionOf s = Region
  { regShard = secShard s
  , regTickStart = secTickStart s
  , regTickEnd = secTickEnd s
  , regEntityMin = secEntityMin s
  , regEntityMax = secEntityMax s
  , regPriority = secPriority s
  }
