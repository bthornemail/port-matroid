# Runtime And Operations Guide

## Runtime Components

- `port-matroidd`: main daemon. Loads config, routing context, snapshot, replays WAL, runs TCP server + UNIX control socket + tick loop.
- `port-matroidctl`: client for control socket framed commands.
- `snapshot-verify`: validates canonical snapshot (`CSNP`) and section (`CSPT`) files.
- `port-matroid-tool`: offline validation, audit, seam-envelope ingest, digest/provenance index operations.

## `port-matroidd` Actual Flow

1. Load config from `--config` path or `/etc/port-matroid/port-matroid.conf`.
2. Read routing context from `<data_dir>/routing.ctx`.
3. Load snapshot via manifest pointer fallback logic.
4. Replay WAL (`replayWalWith cfgWalTruncate`).
5. Initialize node state.
6. Start framed TCP server (`cfgListen`) and UNIX control server (`cfgControl`).
7. Tick loop:
   - run scheduler step
   - decode instruction stream
   - apply instructions to snapshot
   - append WAL (unless readonly)
   - rotate snapshot+WAL every 1000 WAL appends
8. On SIGTERM/SIGINT: close server socket, rotate snapshot+WAL, exit.

## Persistence Contract (Current Code)

Data directory layout (generation-based):

- `snapshots/snap.<gen>.csnp`
- `wal/wal.<gen>.wal`
- `manifest`

Default fallback paths if no generation found:

- `snapshots/latest.csnp`
- `wal/current.wal`

WAL format:

- Header: `PMWAL` + `u16le version` (`walVersion = 1`)
- Entries: `u32le length` + `u32le crc32(payload)` + payload bytes
- Replay fails closed on checksum/header/truncation errors unless truncation mode is enabled.

Manifest:

- Keys: `gen`, `snapshot`, `wal`, optional `crc`
- CRC validates manifest payload when present.
- Runtime uses manifest first; falls back to highest matching snapshot/WAL generation.

## Network And Control Surfaces

Framing:

- Length-prefixed (`u32le`) frames for TCP and control sockets (`Runtime.Net.Framing`).

TCP server:

- Receives framed scheduler-network messages.
- `MsgWorkBundle` updates in-memory workset union.
- `MsgWorkDigest` and `MsgWorkRequest` currently no-op at `Runtime.Node.handleMessage`.
- Replies with empty payload frame.

Control socket commands (implemented):

- `status` -> `ok epoch=<routingEpoch>`
- `dump-snapshot <path>` -> writes encoded snapshot atomically to path
- `dump-snapshot` -> returns snapshot bytes directly

## `port-matroid-tool` Commands (Implemented)

- `validate <file>`: validates `.csnp`, `.workset`, `.ctx`, `.msg`.
- `audit <data-dir>`: snapshot/WAL replay integrity and WAL entry count.
- `append-envelope <data-dir> <events.ndjson>`: strict seam-envelope parse + WAL append.
- `verify-envelope-digest-index <data-dir>`
- `verify-envelope-digest-prefix <data-dir> <n-lines>`
- `rebuild-envelope-digest-index <data-dir>`
- `provenance-index <data-dir> <out.tsv>`
- `verify-provenance-index <data-dir> <out.tsv>`
- `export-snapshot-json <file.csnp>`
- `replay-hash <data-dir>`

## Drift: Man Pages vs Current Implementation

Current man pages include options/commands not implemented in present `app/*/Main.hs` code paths, including:

- `port-matroidd(1)` options like `--data-dir`, `--listen`, etc. are not currently parsed as CLI flags (config-file driven instead).
- `port-matroidctl(1)` documents commands such as `peers`, `dump-wal`, `validate`, `replay` not currently implemented in control handler.

Contributor rule: validate operational docs against source before extending CLIs.

