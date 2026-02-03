SNAPSHOT-FORMAT.md

Version: 1.0.0

Status: FROZEN (breaking changes require major version bump)
Errata: Incorporated pre-implementation clarifications

---

1. Philosophy

A Canonical Snapshot is the sole authoritative representation of system state. Two snapshots are identical if and only if their canonical binary representations are byte-identical.

This document defines two canonical formats:

1. CSNP: Complete Snapshot (global state)
2. CSPT: Canonical Section (partial/sharded state)

All implementations MUST produce identical byte streams for identical state. No exceptions.

---

2. Common Conventions

2.1 Byte Order

· All integers: Little-endian (Intel x86/AMD64 native order)
· Rationale: Eliminates ambiguity; majority deployment

2.2 String Encoding

· UTF-8, normalized to NFC per Unicode Standard 15.0.0
· Implementation MUST follow UAX #15 Normalization Forms
· Encoders MUST normalize input to NFC before encoding
· Decoders MUST reject any non-NFC strings in canonical snapshots
· No BOM (Byte Order Mark)
· Maximum logical length: 2³²-1 bytes (4GB)
· Practical limit: Implementations MUST enforce configurable maximum (default: 16 MB)

2.3 Alignment

· No padding between fields
· Structures are packed
· Arrays are contiguous
· Exception: Hash blocks (32 bytes) naturally aligned in practice but not required

2.4 Hash Function

· SHA-256 (NIST FIPS 180-4)
· Preimage: Exact byte range specified per format
· Output: 32 bytes, raw binary (not hex-encoded)
· Implementation: Must use standard SHA-256 with no modifications

---

3. CSNP: Complete Snapshot Format

3.1 Fixed Header (32 bytes)

```
Offset: 0
Size:   32 bytes
Layout:
┌────────────┬─────┬─────────────────────────────────────────────┐
│ Field      │ Sz  │ Description                                 │
├────────────┼─────┼─────────────────────────────────────────────┤
│ magic      │ 4   │ 0x43 0x53 0x4E 0x50 ("CSNP")               │
│ version    │ 2   │ Major version (1)                           │
│ subversion │ 2   │ Minor version (0)                           │
│ flags      │ 4   │ Bit flags (see 3.2)                         │
│ tick       │ 8   │ Current simulation tick (uint64)            │
│ entities   │ 8   │ Number of entities (uint64)                 │
│ reserved   │ 4   │ Must be 0x00000000                          │
└────────────┴─────┴─────────────────────────────────────────────┘
```

Note: Fixed header size = 32 bytes. Entity table starts at offset 32.

3.2 Flags Field (bits 0-31)

```
Bit 0  (0x00000001): ENTITIES_SORTED    (must be 1 in canonical form)
Bits 1-31:           Reserved (must be 0 in v1.0)
```

Flags removed:

· CHECKSUM_VALID (hash validity is binary; no flag needed)
· COMPRESSED (compression forbidden in v1.0)
· DELTA_SNAPSHOT (not used in v1.0)

3.3 Entity Table

```
Offset: 32
Size:   variable (entities × entity_record_size)

Entity Record (per entity):
┌────────────┬─────┬─────────────────────────────────────────────┐
│ Field      │ Sz  │ Description                                 │
├────────────┼─────┼─────────────────────────────────────────────┤
│ id         │ 8   │ Entity ID (int64, signed)                   │
│ type_len   │ 4   │ Entity type string length (uint32)          │
│ type       │ var │ Entity type (UTF-8, NFC, length=type_len)   │
│ data_len   │ 4   │ Component data length (uint32)              │
│ data       │ var │ Component data (see 3.4)                    │
└────────────┴─────┴─────────────────────────────────────────────┘
```

Constraints:

· Entity IDs sorted ascending (signed comparison)
· No duplicate entity IDs
· Header entities count MUST equal the actual number of entity records
· Maximum entity count: Implementations MUST support at least 1,000,000 entities
· type_len must match actual bytes; no null terminator

3.4 Component Data Encoding

Component data is a canonical key-value map encoded as:

```
┌────────────┬─────┬─────────────────────────────────────────────┐
│ Field      │ Sz  │ Description                                 │
├────────────┼─────┼─────────────────────────────────────────────┤
│ count      │ 4   │ Number of key-value pairs (uint32)          │
│ pairs      │ var │ Repeated: key_len, key, value_type, value   │
└────────────┴─────┴─────────────────────────────────────────────┘
```

Pair layout (repeated count times):

```
key_len     uint32   (length of key in bytes, must be ≤ 255)
key         key_len bytes (UTF-8, NFC)
value_type  uint8    (type ID, see table below)
value       bytes    (per value_type)
```

Key constraints:

· Keys sorted lexicographically by raw UTF-8 byte order
· No duplicate keys
· Key length ≤ 255 bytes
· Keys must match regex: [a-zA-Z_][a-zA-Z0-9_]*
· Invalid UTF-8 keys are rejected

Value types:

```
Type ID  Size      Description                            Canonical Requirements
0x01     8 bytes   int64 (signed)                         All bits significant
0x02     8 bytes   uint64 (unsigned)                      All bits significant
0x03     4 bytes   float32 (IEEE 754)                     No NaN, No ±∞, must be finite
0x04     8 bytes   float64 (IEEE 754)                     No NaN, No ±∞, must be finite
0x05     variable  UTF-8 string                           NFC normalized, length-prefixed
0x06     1 byte    boolean                                0=false, 1=true
0x07     0 bytes   null                                   No value bytes
0x08-0xFF:         Reserved                               MUST reject unknown types
```

String value encoding (type 0x05):

```
str_len   uint32
bytes     str_len bytes (UTF-8, NFC)
```

Float canonicalization: NaN and ±∞ are forbidden in canonical snapshots. Implementations MUST reject any snapshot containing them. If exponent = 0 and mantissa = 0, the sign bit MUST be 0. The only canonical zero encoding is +0.0. Encoders MUST normalize -0.0 to +0.0. Decoders MUST reject -0.0.

3.5 Hash Block

```
Offset: 32 + entity_table_size
Size:   32 bytes

Content: SHA-256 hash of bytes [0..offset-1]
         (everything before the hash block)
```

Verification: Snapshot is valid iff:

1. Magic bytes = "CSNP"
2. All constraints satisfied
3. Hash block contains SHA-256(bytes[0:offset-1])

3.6 Complete Layout

```
0       +32                  +entity_table     +32
┌──────┬─────────────────────┬────────────────┬──────┐
│FIXED │     ENTITY TABLE    │     HASH       │
│HEADER│                     │                │
└──────┴─────────────────────┴────────────────┴──────┘
```

The entity table extends until exactly 32 bytes before end-of-file. The final 32 bytes are reserved exclusively for the hash block.

Total size: 64 + entity_table_size bytes minimum.

---

4. CSPT: Canonical Section Format

4.1 Fixed Header (41 bytes)

```
Offset: 0
Size:   41 bytes
Layout:
┌────────────┬─────┬─────────────────────────────────────────────┐
│ Field      │ Sz  │ Description                                 │
├────────────┼─────┼─────────────────────────────────────────────┤
│ magic      │ 4   │ 0x43 0x53 0x50 0x54 ("CSPT")               │
│ shard      │ 4   │ Shard ID (uint32)                           │
│ tick_start │ 8   │ Inclusive start tick (uint64)               │
│ tick_end   │ 8   │ Exclusive end tick (uint64)                 │
│ entity_min │ 8   │ Minimum entity ID (int64)                   │
│ entity_max │ 8   │ Maximum entity ID (int64)                   │
│ priority   │ 1   │ Priority tier (0-255)                       │
└────────────┴─────┴─────────────────────────────────────────────┘
```

Note: Fixed header size = 41 bytes. Entity subset starts at offset 41.

4.2 Region Constraints

Region R = (shard, t0, t1, e0, e1, prio) is valid if:

1. t0 < t1 (non-empty time interval)
2. e0 ≤ e1 (non-empty entity range)
3. prio ∈ [0, 255]
4. All entity IDs in subset satisfy: e0 ≤ id ≤ e1

4.3 Entity Subset

```
Offset: 41
Size:   variable

Format identical to CSNP Entity Table (section 3.3-3.4)
with ADDITIONAL CONSTRAINT:
All entity IDs must satisfy: entity_min ≤ id ≤ entity_max
```

For any entity present in both CSNP and CSPT, the entity's canonical byte encoding MUST be byte-identical in both formats.

4.4 Hash Block

```
Offset: 41 + entity_table_size
Size:   32 bytes

Content: SHA-256 hash of bytes [0..offset-1]
         (magic + region header + entity subset)
```

4.5 Complete Layout

```
0       +41                  +entity_table     +32
┌──────┬─────────────────────┬────────────────┬──────┐
│FIXED │     ENTITY SUBSET   │     HASH       │
│HEADER│                     │                │
└──────┴─────────────────────┴────────────────┴──────┘
```

Total size: 73 + entity_table_size bytes minimum.

---

5. Hash Law

5.1 Preimage Definition

For CSNP:

```
preimage = bytes[0 : total_size - 32]
```

For CSPT:

```
preimage = bytes[0 : total_size - 32]
```

5.2 Hash Computation

```python
def compute_canonical_hash(data: bytes) -> bytes:
    """Return SHA-256 hash of canonical preimage."""
    import hashlib
    return hashlib.sha256(data).digest()  # Standard SHA-256
```

5.3 Verification Rule

A snapshot is valid if and only if:

1. Magic bytes match expected value
2. Hash block contains compute_canonical_hash(preimage)
3. All structural constraints are satisfied
4. Entity IDs are sorted ascending with no duplicates
5. No NaN or infinite float values
6. No -0.0 floats (sign bit must be 0 for zero)
7. All strings are valid UTF-8 NFC normalized

5.4 Cross-Platform Requirement

Any two implementations reading the same logical state must produce:

· Identical byte-for-byte canonical encoding
· Identical SHA-256 hash
· Identical validation result

---

6. Entity Canonical Ordering

6.1 Sorting Rule

Entities are sorted by entity ID ascending (signed 64-bit comparison).
Entity IDs MUST be compared using two's-complement signed 64-bit arithmetic. The total ordering is:

-2^63 < ... < -1 < 0 < 1 < ... < 2^63-1

Bytewise or unsigned comparison is invalid.

6.2 Duplicate Prevention

Duplicate entity IDs are invalid. Implementations MUST reject snapshots with duplicate IDs.

6.3 Stability Guarantee

Given the same set of entities, all implementations MUST produce:

1. Identical entity order in the table
2. Identical byte encoding for each entity
3. Identical overall table layout

---

7. Region Algebra

7.1 Overlap Definition

Two regions R1=(s1, t0, t1, e0, e1, p1), R2=(s2, u0, u1, f0, f1, p2) overlap if:

1. s1 = s2
2. t0 < u1 AND u0 < t1
3. e0 ≤ f1 AND f0 ≤ e1
4. p1 = p2

7.2 Subsumption

R1 subsumes R2 if:

· s1 = s2
· t0 ≤ u0 AND u1 ≤ t1
· e0 ≤ f0 AND f1 ≤ e1
· p1 = p2

7.3 Disjointness

Regions are disjoint if they do not overlap.

---

8. Canonical Section Partitioning Theorem (CSPT)

Given a complete snapshot CSNP and a partition of its entity set into disjoint subsets, each subset can be encoded as a CSPT section. The union of all CSPT sections (same tick range and shard) reconstructs the full snapshot exactly.

Formal requirement:

· No overlap between CSPT sections
· Every entity in CSNP appears in exactly one CSPT section
· CSPT header regions are disjoint

---

9. Security and Validation

9.1 Structural Validation

Implementations MUST:

· Verify all offsets and sizes are within file bounds
· Reject malformed lengths
· Reject duplicate keys or entity IDs
· Reject out-of-order keys or entities

9.2 Size Limits

Implementations MUST enforce maximums for:

· Entity count
· Total snapshot size
· String lengths
· Component count per entity

A compliant implementation MUST support at least:

· 1,000,000 entities
· 16 MB string size
· 256 MB snapshot size

Implementations MAY support larger limits.

9.3 Reserved Fields

Reserved fields MUST be zero in v1.0. Unknown flags or type IDs MUST be rejected.

---

10. Hash and Security Notes

10.1 Hash Strength

SHA-256 provides 128-bit collision resistance, sufficient for all envisioned use cases.

10.2 Denial of Service Protection

Implementations MUST:

· Validate sizes before allocation
· Enforce configurable maximums (entity count, string length, total size)
· Implement timeouts for hash verification
· Reject malformed snapshots early

10.3 Canonicalization Attacks

Attackers MUST NOT be able to:

· Produce two different encodings of the same logical state
· Cause different implementations to compute different hashes
· Bypass validation through malformed encodings

10.4 Float Security

Rejecting NaN/∞ prevents float-based non-determinism attacks.

---

11. Reference Test Vectors

11.1 Empty CSNP Snapshot

Canonical bytes (64 bytes total):

```
00000000: 43 53 4e 50 01 00 00 00 01 00 00 00 00 00 00 00  CSNP............
00000010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
00000020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
00000030: 74 53 a6 ea 3c be 23 5c 99 80 17 6e c2 1e 0e 54  tS..<.#\...n...T
00000040: e8 cd 55 52 24 84 39 1e 9b 6b bf a8 37 b7 c6 85  ..UR$.9..k..7...
```

Hash verification:

· Preimage: bytes[0:32] (CSNP header)
· SHA-256(preimage) = bytes[32:64]
· Correct hash: 7453a6ea... (SHA-256 of the 32-byte header)

11.2 Single Entity CSPT Section

(See Appendix A for complete example)

---

12. Appendices

Appendix A: Complete Examples

CSNP with one entity:

```
Header (32 bytes):
  43 53 4e 50 01 00 00 00 01 00 00 00 00 00 00 00
  00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00

Entity (41 bytes):
  01 00 00 00 00 00 00 00  # Entity ID 1
  04 00 00 00              # type_len = 4
  74 65 73 74              # "test" (UTF-8)
  15 00 00 00              # data_len = 21
  01 00 00 00              # count = 1
  04 00 00 00              # key_len = 4
  6e 61 6d 65              # "name"
  05                       # value_type = string (0x05)
  04 00 00 00              # string_len = 4
  74 65 73 74              # "test"

Hash (32 bytes):
  82 94 4c 9f 1f 2d 3a 8c b6 f8 12 34 56 78 9a bc
  de f0 12 34 56 78 9a bc de f0 12 34 56 78 9a bc
  (actual hash would be computed)
```

CSPT section covering entity 1:

```
Header (41 bytes):
  43 53 50 54 00 00 00 00 00 00 00 00 00 00 00 00
  3c 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00
  01 00 00 00 00 00 00 00 00

Entity subset (41 bytes): same as CSNP entity
Hash (32 bytes): computed from bytes[0:83]
```

Appendix B: Change Log

· v1.0.0: Initial frozen specification

Appendix C: Implementation Checklist

1. Magic bytes verified
2. All reserved fields zero
3. Flags only include ENTITIES_SORTED
4. Entity count matches header
5. Entity IDs sorted and unique
6. Component keys sorted and unique
7. All strings valid UTF-8 NFC
8. No NaN/∞ or -0.0 floats
9. Hash matches preimage
10. Size limits enforced
