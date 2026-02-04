UNIVERSE-ARCHITECTURE.md

Version: 1.0
Status: Architectural freeze companion to SNAPSHOT + ISA v1

---

1. Purpose

This document defines the architectural model of the universe engine.

It explains how the system is structured, how layers relate, and what invariants must hold across all compliant implementations.

This document is descriptive, not normative.
The normative rules live in:

SNAPSHOT-FORMAT.md (state law)
UNIVERSE-ISA.md (transition law)

This file explains how those laws compose into a deterministic machine.

---

2. Architectural Model

The universe engine is a deterministic state transition system:

Snapshot_n + InstructionStream -> Snapshot_(n+1)

Where:

Snapshot is canonical state
InstructionStream is a finite ordered sequence
Execution is pure and deterministic
Resulting snapshot is canonical

There is no external dependency.

No randomness.
No wall clock.
No host state.

Two compliant implementations must produce byte-identical results.

---

3. Layer Structure

3.1 Snapshot Layer - Storage Law

Defined by: SNAPSHOT-FORMAT.md

The snapshot layer specifies:

canonical binary encoding
canonical ordering
normalization rules
hash law
structural validity

A snapshot is authoritative state.

Two snapshots are identical iff their bytes are identical.

The snapshot layer has no behavior.
It is a pure data model.

3.2 ISA Layer - Transition Law

Defined by: UNIVERSE-ISA.md

The ISA layer specifies:

opcode set
payload encoding
authority checks
semantic validation
deterministic effects
halt conditions

Each instruction is a pure function:

step : Snapshot -> Snapshot

or

step : Snapshot -> HALT

Instructions do not mutate in place.
They define a new canonical snapshot.

3.3 Replay Layer - Consensus Law

Defined by: replay contract tests

The replay layer guarantees:

before + stream = after

byte-for-byte.

This is the consensus invariant.

If replay differs:

implementation is non-compliant
or snapshot/ISA law is violated

Replay is the ultimate correctness oracle.

---

4. Memory Isolation Law

Instruction execution is isolated.

The only persistent state is the snapshot.

An implementation MUST NOT use:

system time
randomness
external I/O
host memory state
thread scheduling
floating-point environment
non-deterministic iteration

Execution must depend only on:

(snapshot bytes, instruction bytes)

Nothing else.

This guarantees cross-machine replay.

---

5. Canonical Ordering Law

All iteration over entities and components MUST follow canonical snapshot ordering.

Implementations may use any internal structure, but observable results must behave as if the canonical ordering were used.

Violation of ordering breaks replay equivalence.

---

6. Determinism Contract

The engine is a deterministic virtual machine.

Given:

S0 + I1..n

all compliant implementations must produce:

Sn

such that:

bytes(Sn) are identical

No equivalent state is allowed.

Only canonical state exists.

---

7. Error Model

Errors are part of the instruction semantics.

A HALT is a valid outcome.

Error priority ordering is fixed and deterministic.

Malformed framing > limit violations > semantic errors

This ensures identical failure behavior across implementations.

---

8. Version Binding

Snapshot version implies ISA version.

A compliant engine MUST reject unsupported versions.

Partial execution is forbidden.

Version mismatch -> HALT.

---

9. Authority Model

Authority is explicit and data-driven.

Execution depends only on:

(snapshot, authority mask, instruction)

Authority is not ambient.

No hidden privileges exist.

Ownership and authority checks are deterministic and reproducible.

---

10. No Undefined Behavior

The universe engine has no undefined behavior.

Every input yields exactly one of:

canonical snapshot
HALT(reason)

There is no implementation-defined gray zone.

---

11. Compliance Definition

An implementation is compliant if it:

passes snapshot golden vectors
passes ISA golden vectors
passes replay contracts
passes halt code vectors
respects canonical ordering
enforces authority law
preserves determinism

Compliance is executable, not interpretive.

---

12. Architectural Summary

The system is a closed machine:

canonical state
+ canonical instructions
= canonical evolution

It is:

replayable
deterministic
authority-safe
byte-locked
spec-anchored

This is not an application protocol.

It is a virtual universe kernel.

---

13. Execution Model Clarifications

13.1 Snapshot Immutability

The semantic model is immutable. Implementations may use structural sharing
internally, but the input snapshot is observationally unchanged after step.

13.2 Prefix Commit Semantics

Instruction streams commit prefix effects. On HALT, prior instructions remain
committed and the failing instruction has no effect.

13.3 Numeric Determinism Boundary

Numeric behavior is governed entirely by canonical snapshot and ISA rules.
Host floating-point semantics MUST NOT leak into execution.

13.4 Resource Exhaustion

Resource exhaustion MUST halt without partial mutation. No best-effort or
truncation behavior is permitted.

---

14. Canonical Identity Laws

14.1 Snapshot Identity Bijection

Snapshot encoding is a bijection between valid semantic states and canonical
byte sequences. No two distinct semantic states may share bytes, and no two
byte sequences may represent the same semantic state.

14.2 Instruction Atomicity

An instruction either produces a fully canonical snapshot or produces no state
change and HALTs. Intermediate states are not observable.

14.3 Allocation Determinism

Internal allocation strategies MUST NOT influence canonical ordering or output
bytes. Allocation order is unobservable.

14.4 Failure Determinism

For any input, the HALT reason is uniquely determined by the error priority
order. Implementations MUST return the same reason.

14.5 Replay Associativity and Prefix Stability

Replay is associative:
replay(S, A ++ B) == replay(replay(S, A), B)

Replay is prefix-stable:
if replay(S, A) HALTs at step k, then replay(S, A ++ B) HALTs at step k.

14.6 Instruction Identity

Instruction meaning is fully determined by canonical bytes. Two byte-identical
instructions MUST produce identical effects in all compliant implementations.

14.7 Fail-Closed Compatibility

Unknown opcodes, unknown fields, or unknown versions MUST HALT. Best-effort
decoding is forbidden.

---

15. State Transition Axiom

The universe is a deterministic state transition system:

U_{n+1} = Step(U_n, I_n)

Where Step is total and returns either:

Next(snapshot) or Halt(reason)

For a stream:

U_n = foldl Step U_0 stream

No external side channels are permitted.

---

16. Determinism Boundary

Instruction semantics MUST NOT depend on host runtime behavior such as:

clock
randomness
thread scheduling
memory layout
pointer identity
locale
floating-point environment

Only canonical bytes are observable inputs.

---

17. Universe Identity Law

A universe is uniquely identified by:

1) The canonical snapshot bytes of its current state
2) The canonical instruction stream that produced it

This enables deterministic replay, audit, and forking.

---

18. Version Negotiation Law

Unknown or unsupported snapshot or ISA versions MUST halt. No silent downgrade,
best-effort decode, or partial execution is permitted.
