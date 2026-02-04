STORAGE-FORMAT.md

Runtime Storage Format (v1 Frozen Draft)

Status
Consensus-adjacent. This document defines the on-disk crash-consistent storage format.
Any deviation may break recovery determinism.

This format is a runtime concern layered on top of:

- SNAPSHOT-FORMAT.md (canonical snapshot bytes)
- UNIVERSE-ISA.md (instruction semantics)
- SCHEDULER-CUBE.md (workset semantics)

---

1. Goals

The storage layer MUST provide:

deterministic recovery
crash consistency (power loss at any time)
fail-closed corruption detection
auditability without mutation

This is achieved via:

immutable snapshots
append-only WAL segments
atomic manifest pointer (written last)
checksums (CRC32)
strict format versioning

---

2. Files and Directories

data_dir/
  manifest
  snapshots/
    snap.<gen>.csnp
  wal/
    wal.<gen>.wal

The manifest is the authoritative pointer to the active snapshot + WAL pair.
Snapshots and WALs are immutable once written.

---

3. Manifest Format (v1)

Text file with key=value lines.

Grammar:

gen=<integer>
snapshot=<path>
wal=<path>
crc=<uint32>

Lines may include:

blank lines (ignored)
comment lines beginning with '#'
CRLF or LF line endings

Key ordering is not significant.

3.1 CRC

crc is CRC32 over the payload:

gen=<integer>\n
snapshot=<path>\n
wal=<path>\n

CRC is computed over the UTF-8 bytes of the payload.

If crc is missing, the manifest is accepted for backward compatibility but audit must report manifest_crc=missing.

3.2 Validity

Manifest is valid iff:

gen parses as integer
snapshot path present
wal path present
crc (if present) matches payload

Otherwise: fail closed.

---

4. Snapshot Files

Snapshots are canonical bytes as defined in SNAPSHOT-FORMAT.md.

Filename:

snap.<gen>.csnp

Snapshots are immutable.

---

5. WAL Files

WAL files are append-only binary logs.

Filename:

wal.<gen>.wal

5.1 Header

WAL header is:

magic = "PMWAL" (5 bytes)
version = u16le

v1 header bytes:

0x50 0x4d 0x57 0x41 0x4c 0x01 0x00

Header must be present and valid before any entries.

If missing or mismatched: fail closed.

5.2 Entry Format

Each entry:

len : u32le
crc : u32le
payload : bytes[len]

CRC is CRC32 of payload bytes.

5.3 Payload

Payload is an instruction stream encoded per UNIVERSE-ISA.md.

---

6. Rotation and Crash Atomicity

Rotation procedure:

1) Write snapshot to temp file
2) fsync temp file
3) rename temp -> snap.<gen>.csnp
4) fsync snapshots directory
5) Write wal.<gen>.wal with header only
6) fsync wal file
7) rename wal temp -> wal.<gen>.wal
8) fsync wal directory
9) Write manifest (temp + fsync + rename + fsyncDir) LAST

The manifest is the commit record. It is written after snapshot + WAL are durable.

Crash at any point yields either:

old manifest (old state)
or new manifest (new state)

No partial state is observable.

---

7. Recovery Algorithm

Given data_dir:

1) Read manifest.
2) If valid, use manifest snapshot + WAL paths.
3) If missing, fall back to highest generation where both snapshot and WAL exist.
4) Decode snapshot.
5) Replay WAL entries in order.
6) If any entry fails checksum or decode: fail closed.

Optional mode:

wal_truncate=true allows truncation of a trailing partial entry only.

CRC mismatch always fails closed.

---

8. Audit Mode

Audit reads manifest, snapshot, WAL and verifies:

manifest CRC (if present)
WAL header and version
CRC of every entry
replay succeeds deterministically

Audit output should include:

gen
wal_entries
wal_version
manifest_crc status (ok|missing)

---

9. Compatibility

Unknown WAL versions MUST be rejected.

Unknown manifest keys MUST be ignored.

Missing CRC is allowed for backward compatibility but should be reported.

---

10. Compliance Checklist

An implementation is compliant iff:

- manifest CRC is verified if present
- WAL header and version are validated
- WAL CRC is checked per entry
- rotation writes manifest last (atomic)
- recovery is deterministic and fail-closed
- audit reports integrity status

---

END OF DRAFT
