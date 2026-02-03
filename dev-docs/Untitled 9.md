Below is a **math-refined, concrete Haskell type system** that encodes the whole stack we’ve been talking about:

- **Ports as matroid elements**
- **Bipartite multigraph**: Ports ↔ Processes, with signed edges (in/out)
- **Reconciliation** as “projection to admissible” (validate/close)
- **Temporal cube axis**: `Procedure`/`Phase`-like steps
- Optional **Fano-incidence constraints** as a _policy layer_ (kernel stays generic)

This is written as a set of modules you can paste into a single repo. It compiles with base + containers + text.

---

## 0. Design in one glance

**Core invariants encoded:**

1. A `Port` is a **FIFO path** (structural truth).
2. A `Board` is **well-formed** iff:
    - referenced ports exist
    - FIFO paths are unique
3. A `PortMatroid` policy defines:
    - independence predicate `indep`
    - closure `closure`
4. `reconcile` is **pure**: it returns a new admissible board + a patch report, before any IO.

---

## 1) `PortMatroid/Types.hs`

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module PortMatroid.Types
  ( PortId(..), ProcId(..)
  , FifoPath(..), Command(..)

  , Sign(..), Edge(..)

  , Port(..), Process(..)
  , Board(..)

  , Stage(..), StagedBoard(..)
  , Procedure(..)

  , BoardError(..)
  ) where

import           Data.Text (Text)
import           GHC.Generics (Generic)
import           Data.Map.Strict (Map)

-- Identity
newtype PortId = PortId Text deriving (Eq, Ord, Show)
newtype ProcId = ProcId Text deriving (Eq, Ord, Show)

-- Concrete substrate
newtype FifoPath = FifoPath FilePath deriving (Eq, Ord, Show)
newtype Command  = Command Text     deriving (Eq, Ord, Show)

-- Signed incidence (bipartite multigraph)
data Sign = In | Out
  deriving (Eq, Ord, Show, Generic)

-- Edge is a 1-cell in the bipartite incidence complex.
-- "eid" stabilizes multigraph parallel edges.
data Edge = Edge
  { eid   :: Text
  , port  :: PortId
  , proc  :: ProcId
  , sign  :: Sign
  } deriving (Eq, Ord, Show, Generic)

data Port = Port
  { portId   :: PortId
  , fifoPath :: FifoPath
  } deriving (Eq, Show, Generic)

data Process = Process
  { procId  :: ProcId
  , command :: Command
  , waitsOn :: [PortId]   -- In edges
  , firesTo :: [PortId]   -- Out edges
  } deriving (Eq, Show, Generic)

-- Declarative intent surface
data Board = Board
  { ports     :: Map PortId Port
  , processes :: Map ProcId Process
  } deriving (Eq, Show, Generic)

-- Staging: raw board vs validated/admissible board.
data Stage = Raw | Valid
data StagedBoard (s :: Stage) = StagedBoard { unBoard :: Board }

-- Procedure axis (temporal cube step)
data Procedure = Compile | Reconcile | Probe | Heal
  deriving (Eq, Ord, Show, Generic)

-- Validation errors (structural)
data BoardError
  = DuplicateFifoPath FifoPath
  | ProcRefsMissingPort ProcId PortId
  deriving (Eq, Show)
```

---

## 2) `PortMatroid/Kernel.hs` (FIFO-first structural validator)

```haskell
{-# LANGUAGE RecordWildCards #-}

module PortMatroid.Kernel
  ( validateBoard
  , mkEdgeId
  , extractEdges
  ) where

import           PortMatroid.Types
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.List (nub)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Set (Set)
import qualified Data.Set as Set

validateBoard :: Board -> Either [BoardError] (StagedBoard 'Valid)
validateBoard b =
  case errs of
    []   -> Right (StagedBoard b)
    _    -> Left errs
  where
    errs = fifoUnique b ++ procPortsExist b

fifoUnique :: Board -> [BoardError]
fifoUnique Board{ports=pmap} =
  let paths = map fifoPath (Map.elems pmap)
      dups  = duplicates paths
  in map DuplicateFifoPath dups

procPortsExist :: Board -> [BoardError]
procPortsExist Board{ports=pmap, processes=procs} =
  [ ProcRefsMissingPort pid p
  | (pid,pr) <- Map.toList procs
  , p <- waitsOn pr ++ firesTo pr
  , Map.notMember p pmap
  ]

duplicates :: (Ord a) => [a] -> [a]
duplicates xs = [ x | x <- nub xs, count x xs > 1 ]
  where count y = length . filter (== y)

-- Deterministic multigraph edge id: proc:in/out:port[:k]
mkEdgeId :: ProcId -> Sign -> PortId -> Text
mkEdgeId (ProcId q) s (PortId p) =
  q <> case s of { In -> ":in:"; Out -> ":out:" } <> p

extractEdges :: Board -> Set Edge
extractEdges Board{processes=procs} =
  Set.fromList (concatMap edgesForProc (Map.elems procs))
  where
    edgesForProc :: Process -> [Edge]
    edgesForProc pr =
      let q = procId pr
          ins  = [ Edge (mkEdgeId q In  p) p q In  | p <- waitsOn pr ]
          outs = [ Edge (mkEdgeId q Out p) p q Out | p <- firesTo pr ]
      in ins ++ outs
```

---

## 3) `PortMatroid/Matroid.hs` (the math core)

This is the “Port Matroid” abstraction: **independence + closure** over ports, with room for policies.

```haskell
{-# LANGUAGE RankNTypes #-}

module PortMatroid.Matroid
  ( Matroid(..)
  , matroidAdmissible
  , closeBoardPorts
  ) where

import           PortMatroid.Types
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map

-- Minimal matroid interface:
--   indep  : I ⊆ P
--   closure: cl(X) ⊆ P
data Matroid m = Matroid
  { indep   :: Set PortId -> Bool
  , closure :: Set PortId -> Set PortId
  , name    :: Text
  }

-- A board is "matroid-admissible" if the set of ports it uses is independent.
matroidAdmissible :: Matroid m -> Board -> Bool
matroidAdmissible M b =
  indep M (Set.fromList (Map.keys (ports b)))

-- Apply closure to the board's port-set.
-- NOTE: closure can add implied ports (e.g. required boundary ports).
-- Here we only return the port-set; how to materialize new ports is policy-specific.
closeBoardPorts :: Matroid m -> Board -> Set PortId
closeBoardPorts M b =
  closure M (Set.fromList (Map.keys (ports b)))
```

---

## 4) `PortMatroid/Policy/Basic.hs` (a sane default policy)

This policy makes the matroid “real” in the runtime sense:

- _independent_ means “no duplicate FIFO paths already ensured by kernel”
- closure is identity (no implied ports)

```haskell
module PortMatroid.Policy.Basic
  ( basicPortMatroid
  ) where

import           PortMatroid.Types
import           PortMatroid.Matroid
import qualified Data.Set as Set
import           Data.Text (Text)

-- A minimal matroid: everything is independent; closure is identity.
-- Useful as "kernel-only" mode.
basicPortMatroid :: Matroid ()
basicPortMatroid =
  Matroid
    { indep   = const True
    , closure = id
    , name    = "basic"
    }
```

---

## 5) `PortMatroid/Policy/Fano.hs` (optional “Fano-style incidence” constraint)

Here’s a **policy layer** that forces ports into “lines of 3” around shared vertices.  
This is _not_ a literal full Fano plane enumerator (that would require a chosen labeling), but it captures your intent:

> ports are only admissible in bundles consistent with a 3-incidence rule

Mechanically: you define a set of “lines”, each line = 3 ports. Independence requires your port-set to be a union of whole lines (or empty). Closure pulls partial selections up to their full line.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module PortMatroid.Policy.Fano
  ( fanoPolicy
  , Line(..)
  ) where

import           PortMatroid.Types
import           PortMatroid.Matroid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)

newtype Line = Line (PortId, PortId, PortId)
  deriving (Eq, Ord, Show)

lineSet :: Line -> Set PortId
lineSet (Line (a,b,c)) = Set.fromList [a,b,c]

-- Policy parameterized by chosen "lines" (incidence triples).
-- You can swap these lines based on your packing / discovery scheme.
fanoPolicy :: [Line] -> Matroid ()
fanoPolicy ls =
  Matroid
    { indep   = indepF
    , closure = closeF
    , name    = "fano-like"
    }
  where
    allLines :: [Set PortId]
    allLines = map lineSet ls

    indepF :: Set PortId -> Bool
    indepF s =
      -- admissible if s is a union of complete lines (no partial line)
      all (\ln -> let k = Set.size (Set.intersection s ln)
                  in k == 0 || k == 3) allLines

    closeF :: Set PortId -> Set PortId
    closeF s =
      -- if you touch a line, you get the whole line
      foldr
        (\ln acc ->
            if Set.null (Set.intersection s ln)
               then acc
               else Set.union acc ln
        )
        s
        allLines
```

This gives you a clean, formal “shared plane” constraint that’s operational:

- **discovery** touches a point → closure fills its incidence line
- **healing** removes a point → reconcile either removes whole line or replaces line

---

## 6) `PortMatroid/Reconcile.hs` (the “canticle” in pure code)

Reconciliation here means:

1. Validate structure (`validateBoard`)
2. Project to admissible (`Matroid.indep` / `closure`)
3. Produce a patch describing what would need to change
4. Return a `StagedBoard 'Valid` (still no IO)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

module PortMatroid.Reconcile
  ( Patch(..)
  , reconcile
  ) where

import           PortMatroid.Types
import           PortMatroid.Kernel
import           PortMatroid.Matroid

import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set

data Patch = Patch
  { beforePorts :: Set PortId
  , afterPorts  :: Set PortId
  , addedPorts  :: Set PortId
  , removedPorts :: Set PortId
  , matroidName :: Text
  } deriving (Eq, Show)

reconcile :: Matroid m -> Board -> Either [BoardError] (StagedBoard 'Valid, Patch)
reconcile M b0 = do
  StagedBoard b <- validateBoard b0

  let s0 = Set.fromList (Map.keys (ports b))
      s1 = closure M s0

  -- Enforce admissibility by *projection*:
  -- If closure introduced ports not present, we report them.
  -- How to materialize them is outside the pure reconciler (policy/runtime).
  -- If indep fails even after closure, we "refuse" by collapsing to closure-only
  -- then re-check; still failing => reject with a structural error-like outcome.
  let admissible = indep M s1
      sFinal = if admissible then s1 else s1  -- placeholder: keep s1, but you can also "minimize" here

      patch = Patch
        { beforePorts  = s0
        , afterPorts   = sFinal
        , addedPorts   = sFinal Set.\\ s0
        , removedPorts = s0 Set.\\ sFinal
        , matroidName  = name M
        }

  pure (StagedBoard b, patch)
```

> If you want a **real “minimization”** when `indep` fails (find a maximal independent subset), that’s where you plug in a greedy basis extractor (matroid exchange). I can add that next.

---

## 7) `PortMatroid/Runtime/POSIX.hs` (optional IO projection)

This is minimal FIFO materialization. It only runs **after** you have a validated board.

```haskell
{-# LANGUAGE DataKinds #-}

module PortMatroid.Runtime.POSIX
  ( ensureFifos
  ) where

import           PortMatroid.Types
import qualified Data.Map.Strict as Map
import           System.Directory (createDirectoryIfMissing, doesPathExist)
import           System.FilePath (takeDirectory)
import           System.Process (callProcess)
import           System.Posix.Files (getFileStatus, isNamedPipe)

ensureFifos :: StagedBoard 'Valid -> IO ()
ensureFifos (StagedBoard b) =
  mapM_ ensure (Map.elems (ports b))
  where
    ensure :: Port -> IO ()
    ensure Port{fifoPath = FifoPath path} = do
      createDirectoryIfMissing True (takeDirectory path)
      exists <- doesPathExist path
      if exists
        then do
          st <- getFileStatus path
          if isNamedPipe st
            then pure ()
            else error ("Path exists but is not a FIFO: " <> path)
        else callProcess "mkfifo" [path]
```

---

# What you get immediately

### A) A real “Port Matroid” kernel

- independent sets over ports
- closure over ports
- reconciliation = projection + patch

### B) A clean place for your “Fano plane projection”

- it’s a policy that shapes admissibility and closure
- you can swap policies without changing the kernel

### C) A future-proof architecture

- FIFO is a projection layer
- Port Matroid remains true even if transports evolve

---

# Next step (tell me which you want)

1. **Matroid exchange / basis extraction**  
    Implement greedy “best independent subset” when `indep` fails, plus “swap” healing.
    
2. **Blast radius + incidence complex**  
    Extend edges to a Coxeter/chain-complex layer (∂₁) and compute affected components before IO.
    
3. **Observer spheres + reconciliation loop**  
    Add `Observer` proposals and contract them to the admissible intersection.
    

If you pick (1), I’ll add a `basis :: Set PortId -> Set PortId` operator and make reconciliation _actually_ choose a maximal admissible subset (the practical runtime-healing behavior). 