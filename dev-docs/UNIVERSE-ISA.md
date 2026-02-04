UNIVERSE-ISA.md

Version: 1.0.0
Status: DRAFT — candidate for freeze after implementation
Depends on: SNAPSHOT-FORMAT v1

---

1. Philosophy

The Universe Instruction Set Architecture (U-ISA) defines the only legal transitions between canonical snapshots.

A Universe is a deterministic state machine:

Snapshot × Instruction → Snapshot | HALT

No hidden state exists outside the snapshot.

If two implementations start from the same snapshot and execute the same instruction stream, they MUST produce identical snapshots or identical HALT reasons.

This document defines:

the opcode set
structural preconditions
authority checks
deterministic effects
failure semantics

---

2. Execution Model

2.1 Step Function

step : Snapshot → Instruction → Result

Result =
  | Next Snapshot
  | Halt HaltReason

Execution is atomic:

Either the instruction fully commits

Or the snapshot remains unchanged

There is no partial mutation.

2.2 Determinism Law

The step function MUST be:

pure
total
deterministic

No randomness.
No clock access.
No IO.
No external state.

All inputs must be encoded in:

the snapshot
the instruction payload

---

3. Instruction Encoding

Instructions are canonical binary objects:

Instruction =
  opcode : Word16
  flags  : Word16
  payload_len : Word32
  payload : bytes[payload_len]

All integers: little-endian.

Unknown opcodes MUST produce:

HALT: ErrUnknownOpcode

3.0.2 Instruction Flags (v1)

flags MUST be 0x0000 in v1. Any nonzero flags MUST halt with ErrMalformedInstruction.
Bits are reserved for future versions.

3.0.3 Canonical Instruction Length

instruction_len MUST equal 8 + payload_len.
If instruction_len does not match payload_len, or if trailing bytes remain,
decoding MUST halt with ErrMalformedInstruction.

3.0 ISA Version Binding

The ISA version is implied by the snapshot header version.
Instructions carry no explicit ISA version field.
If snapshot version is unsupported, execution MUST halt with ErrInternalInvariant.

3.0.1 Instruction Decoding Law

Decoding MUST halt with ErrMalformedInstruction if any of the following apply:
- instruction_bytes shorter than header (8 bytes)
- payload_len exceeds remaining bytes
- instruction_len exceeds stream bounds (when decoding streams)
- integer overflow occurs during length computation
- trailing bytes remain after instruction_len

Decoding failures occur before any semantic or authority checks and obey the
error priority order in section 7.1.

3.1 Canonical Payload Encoding

All payload fields are encoded in a fixed order with no padding.

String encoding:
- UTF-8 NFC
- No BOM
- length-prefixed with uint32 length in bytes

Payload layouts:

NOP (0x0001):
- payload_len = 0

CREATE_ENTITY (0x1001):
- entity_id : int64
- type_len  : uint32
- type      : bytes[type_len]
- owner_mask: uint64 (initial ownership mask)

DELETE_ENTITY (0x1002):
- entity_id : int64

SET_COMPONENT (0x2001):
- entity_id : int64
- key_len   : uint32 (1..255)
- key       : bytes[key_len] (ASCII identifier)
- value_type: uint8 (same domain as snapshot Value)
- value     : bytes (per snapshot Value encoding)

REMOVE_COMPONENT (0x2002):
- entity_id : int64
- key_len   : uint32 (1..255)
- key       : bytes[key_len] (ASCII identifier)

ADVANCE_TICK (0x3001):
- delta     : uint64 (must be > 0)

No optional fields. No implicit defaults. No alignment padding.

3.1.1 Instruction Canonicalization Policy

Encoders MUST normalize inputs to canonical form:
- UTF-8 NFC normalization for strings
- -0.0 canonicalized to +0.0 for float values

Decoders MUST reject non-canonical encodings at semantic validation time.
Structural decoding is limited to framing, length, and type-tag correctness.

3.2 Instruction Canonical Identity

Two instructions are identical iff their canonical byte encoding is identical.
Instruction hash:

instruction_hash = SHA-256(canonical_instruction_bytes)

3.2.1 Halt Reason Codes (v1)

HALT reasons are serialized as uint16 codes:

0x0001 ErrUnknownOpcode
0x0002 ErrUnauthorized
0x0003 ErrEntityExists
0x0004 ErrEntityMissing
0x0005 ErrInvalidKey
0x0006 ErrInvalidValue
0x0007 ErrInvalidType
0x0008 ErrInvalidTick
0x0009 ErrCanonicalViolation
0x000A ErrLimitExceeded
0x000B ErrInternalInvariant
0x000C ErrMalformedInstruction

---

3.3 Instruction Stream Encoding

InstructionStream is a length-prefixed array:

stream_len : uint32
repeated stream_len times:
  instruction_len : uint32
  instruction_bytes : bytes[instruction_len] (canonical)

apply(S, stream) = foldl(step, S, instructions)

---

4. Authority Model

Each entity has an authority mask:

authority : BitSet64

Each opcode defines a required authority bit.

Execution rule:

if not hasAuthority(entity, opcode):
  HALT ErrUnauthorized

Authority is checked before any mutation.

No instruction may escalate its own authority.

4.0 Authority Source

Authority is an explicit external parameter to execution:

step : Snapshot → AuthorityMask → Instruction → Result

Authority is not stored in snapshot bytes and is not encoded in instruction bytes.
All authority decisions MUST be based on the provided AuthorityMask.
Unknown authority bits MUST be zero in v1.

4.1 Ownership Model (v1)

Ownership is defined by the entity component key "_owner":
- If present, it MUST be a uint64 authority mask.
- If absent, ownership is undefined and ADMIN is required.

DELETE_ENTITY requires either:
- caller has ADMIN
- or caller authority intersects _owner

SET_COMPONENT and REMOVE_COMPONENT require:
- caller has WRITE
- and if _owner is present, caller authority intersects _owner

CREATE_ENTITY requires:
- caller has CREATE

ADVANCE_TICK requires:
- caller has ADMIN

4.2 Reserved Ownership Semantics

The key "_owner" is reserved. It may only be set or removed by ADMIN.
Non-ADMIN attempts to mutate "_owner" MUST halt with ErrUnauthorized.

4.1 Authority Bits (v1)

Bit 0: CREATE
Bit 1: DELETE
Bit 2: WRITE
Bit 3: ADMIN
Bits 4-63: Reserved (must be 0 in v1)

---

5. Opcode Set (v1)

Reserved opcode ranges:

0x0000–0x0FFF : core universe ops
0x1000–0x1FFF : entity lifecycle
0x2000–0x2FFF : component mutation
0x3000–0x3FFF : scheduling / time
0xF000–0xFFFF : reserved

---

5.1 NOP

Opcode: 0x0001
Payload: empty

Effect: No change.

Use: heartbeat / liveness / deterministic padding

Failure: never

---

5.2 CREATE_ENTITY

Opcode: 0x1001
Payload:
  entity_id : int64
  type : string
  owner_mask : uint64

Preconditions:

entity_id not present

type valid UTF-8 NFC

caller has CREATE authority

Postconditions:

new entity exists

empty component map

Failure:

ErrEntityExists
ErrUnauthorized
ErrInvalidType

---

5.3 DELETE_ENTITY

Opcode: 0x1002
Payload:
  entity_id : int64

Preconditions:

entity exists

caller owns entity or has ADMIN authority

Effect:

entity removed

Failure:

ErrEntityMissing
ErrUnauthorized

---

5.4 SET_COMPONENT

Opcode: 0x2001
Payload:
  entity_id
  key
  value

Preconditions:

entity exists

key valid ASCII identifier

value canonical per snapshot law

caller has WRITE authority

Effect:

component[key] = value

Failure:

ErrEntityMissing
ErrInvalidKey
ErrUnauthorized
ErrInvalidValue

---

5.5 REMOVE_COMPONENT

Opcode: 0x2002
Payload:
  entity_id
  key

Effect:

remove key if exists

Failure:

ErrEntityMissing
ErrUnauthorized

---

5.6 ADVANCE_TICK

Opcode: 0x3001
Payload:
  delta : uint64

Preconditions:

delta > 0

no overflow (if tick + delta overflows uint64, HALT ErrInvalidTick)

Effect:

snapshot.tick += delta

Failure:

ErrInvalidTick

---

6. Canonical Mutation Law

All mutations must preserve snapshot invariants:

entity IDs remain sorted

component keys remain sorted

NFC enforced

float canonicalization enforced

size limits respected

hash recomputed

If a mutation would violate canonical encoding:

HALT ErrCanonicalViolation

---

7. Failure Semantics

HALT is terminal for the instruction:

state_after = state_before

Reasons:

ErrUnknownOpcode
ErrUnauthorized
ErrEntityExists
ErrEntityMissing
ErrInvalidKey
ErrInvalidValue
ErrInvalidType
ErrInvalidTick
ErrCanonicalViolation
ErrLimitExceeded
ErrInternalInvariant
ErrMalformedInstruction

HALT reasons are part of consensus:

Two implementations must produce identical error codes.

7.1 Error Priority Order

If multiple failures apply, the first matching condition below MUST be returned:

1. Instruction decoding errors (length, payload mismatch)
2. Structural validation errors (invalid UTF-8, invalid key, invalid value type)
3. Authority failures (ErrUnauthorized)
4. Semantic preconditions (missing entity, entity exists, invalid tick)
5. Canonical invariant failures (ErrCanonicalViolation)
6. Resource limits (ErrLimitExceeded)
7. Internal invariant failures (ErrInternalInvariant)

---

7.2 Limit Priority

Instruction size limits are checked immediately after decoding the header and
before any semantic validation. If a limit is exceeded, ErrLimitExceeded MUST
be returned even if other errors would also apply.

---

8. Instruction Replay Law

Instruction streams must be replayable:

apply(apply(S, I1), I2)
==
apply(S, [I1, I2])

Reconciliation engines depend on this property.

8.2 Replay Contract Law

For any canonical snapshot S and instruction stream I:
R = apply(S, I) MUST be canonical.
If two compliant implementations compute R1 = apply(S, I) and R2 = apply(S, I),
then encodeSnapshot(R1) == encodeSnapshot(R2). Replay determinism is consensus-critical.

8.1 Stream Halt Semantics

apply(S, [I1..In]) executes in order:
for k in 1..n:
  r = step(S, Ik)
  if r = Halt: return Halt and current S
  else S = Next(S)
return Next(S)

---

9. Deterministic Merge Compatibility

Instructions must commute when acting on disjoint entities:

I(A) ∘ I(B) = I(B) ∘ I(A)

If they overlap:

→ ordering must be explicit
→ or HALT

This prevents hidden race conditions.

9.1 Touch Set Definition

touches(I) is the set of entity IDs mentioned by an instruction:
- CREATE_ENTITY touches {entity_id}
- DELETE_ENTITY touches {entity_id}
- SET_COMPONENT touches {entity_id}
- REMOVE_COMPONENT touches {entity_id}
- ADVANCE_TICK touches {} (time only)

Two instructions commute iff:
touches(I1) ∩ touches(I2) = ∅

---

10. Security Constraints

no instruction may allocate unbounded memory

no instruction may create NaN/∞

no instruction may produce invalid UTF-8

no instruction may bypass authority

Violation:

ErrCanonicalViolation

---

10.1 Instruction Resource Limits

Implementations MUST enforce configurable maximums:

- max_instruction_size
- max_payload_size
- max_instructions_per_stream

Exceeding limits MUST halt with ErrLimitExceeded.

10.2 Deterministic Resource Accounting

Resource usage MUST be a pure function of:
- instruction byte size
- number of entities touched
- component count in payload

Implementations MUST NOT allocate based on host-specific behaviors.

10.2.1 Resource Accounting Scope (v1)

Deterministic metering is out of scope for v1 beyond the hard limits in 10.1.
If metering is implemented, it MUST be deterministic and documented.

---

11. Versioning

U-ISA version is embedded in snapshot header.

Major change: new opcode semantics

Minor change: new opcode added

Old opcodes must never change behavior.

---

12. Freeze Declaration

When frozen:

This instruction set defines the legal physics of the universe.

Breaking changes require:

UNIVERSE-ISA v2

Not patch releases.

---

END OF DRAFT

---

13. Compliance Checklist (v1)

- Instruction bytes encoded canonically per 3.1
- Instruction hash identity per 3.2
- Stream encoding per 3.3
- Authority bits enforced per 4.1
- Error priority order per 7.1
- Canonical mutation law enforced per 6
- Resource limits enforced per 10.1
- Replay law holds per 8
- Decoding law enforced per 3.0.1
- Canonicalization policy enforced per 3.1.1
- Authority source and ownership per 4.0 and 4.1
- Touch set definition per 9.1
- Deterministic resource accounting per 10.2
- Halt reason codes per 3.2.1
- Flags and instruction_len laws per 3.0.2 and 3.0.3
- Authority requirements per 4.1
- Reserved _owner semantics per 4.2
- Unknown authority bits zero in v1 per 4.0

---

14. Consensus Closure Rules (v1)

14.1 Canonicalization is Semantics

After every successful instruction, the resulting snapshot MUST be canonicalized
via SNAPSHOT-FORMAT encoding and decoding. The committed state is the canonical
snapshot, not any intermediate in-memory representation.

14.2 Entity Type Immutability

Entity type is immutable after creation. There is no legal mutation that changes
an entity's type. Type change requires DELETE_ENTITY followed by CREATE_ENTITY.

14.3 Stream Commit Semantics

Instruction streams commit prefix effects. If an instruction halts, all prior
successful instructions remain committed. There is no stream-level rollback.

14.4 Consensus Limits

Limits that affect acceptance or rejection are consensus-critical and MUST be
identical across implementations. Implementation-local limits MAY be stricter
but MUST only produce ErrLimitExceeded.

14.5 Instruction Hash Role

Instruction hash is an informational identity for logging, deduplication, and
auditing. It does not alter execution semantics.

14.6 Owner Mask Zero Semantics

If owner_mask = 0, the entity is ADMIN-only. No non-ADMIN authority grants access.

14.7 No Undefined Behavior

All integer overflows, invalid encodings, and illegal states MUST halt with a
specified error. No undefined behavior is permitted.
