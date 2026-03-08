# Port-Matroid Contributor Overview

## Purpose

This document is the fastest code-grounded orientation for contributors.
It describes what the repository currently does, where protocol truth lives, and how to start safely.

## What Is Implemented

The current implementation provides:

- Canonical snapshot and section encoding/decoding with strict validation and hash law.
- A deterministic universe instruction engine (decode/encode, step, replay/halt behavior, authority checks).
- Deterministic scheduler workset validation, union, and batch construction.
- Deterministic routing context validation and shard-to-replica routing.
- Scheduler network message codecs plus digest canonicality and replica authority checks.
- Runtime persistence and node loop: manifest, snapshots, WAL, replay, rotation, control socket, framed TCP server.
- Gossip pull protocol primitives for snapshot/WAL anti-entropy.
- CLI tools for validation, audit, seam-envelope ingestion, digest/provenance indexing, and replay hash.

## Where Truth Lives

Use this precedence when documenting or changing behavior:

1. `src/` and `app/` code (actual runtime behavior)
2. `test/` suites and fixtures (executable invariants)
3. frozen spec docs under `dev-docs/` (normative intent)
4. man pages and exploratory notes (may lag implementation)

If these disagree, treat `src/` + `test/` as current-reality for contributor docs, and call out drift explicitly.

## Core Subsystems

- Snapshot law: `Snapshot.Types`, `Snapshot.Encode`, `Snapshot.Decode`, `Snapshot.Errors`, `Snapshot.Limits`.
- Universe law: `Snapshot.Universe.Types`, `Snapshot.Universe.Core`.
- Scheduler law: `Snapshot.Scheduler.*`.
- Routing law: `Snapshot.Routing.*`.
- Scheduler network law: `Snapshot.Scheduler.Network.*`.
- Runtime persistence and services: `Runtime.Store`, `Runtime.Node`, `Runtime.Server`, `Runtime.Control`, `Runtime.Net.*`.
- Operational tools: `app/Main.hs`, `app/port-matroidd/Main.hs`, `app/port-matroidctl/Main.hs`, `app/port-matroid-tool/Main.hs`.

## Quickstart

```bash
cabal build
cabal test all --test-show-details=direct
```

Useful focused runs:

```bash
cabal test golden
cabal test property
cabal test universe
cabal test scheduler-golden
cabal test routing-golden
cabal test network-state
```

## Contributor Caveats

- Some man-page commands/options describe behavior not present in current code paths. Verify against `app/*/Main.hs`.
- Several QuickCheck suites can print `*** Failed!` lines while the suite still exits `PASS` due runner structure. Always read logs and properties carefully before assuming green means complete.

