RECONCILIATION-INVARIANTS.md

Version: 0.1
Status: Draft (intended to be frozen once reconciliation algorithm is fixed)

This document defines formal invariants for reconciliation over canonical snapshots
(CSNP) and canonical sections (CSPT). These invariants are stated in terms of the
frozen binary law in SNAPSHOT-FORMAT.md and are intended to be enforced by tests.

---

1. Definitions

1.1 Canonical Encodings

- encodeSnapshot / encodeSection produce canonical bytes.
- decodeSnapshot / decodeSection accept only canonical bytes.

1.2 Regions

A region R is a 6-tuple:
  R = (shard, t0, t1, e0, e1, priority)
using the constraints in SNAPSHOT-FORMAT.md.

1.3 Section Agreement (from SNAPSHOT-FORMAT.md)

Two CSPT sections S1 (region R1) and S2 (region R2) agree on overlap iff every
entity in R1 intersect R2 has byte-identical canonical encoding in both sections.

1.4 Restriction

restrict(S, R) is the canonical CSPT encoding obtained by restricting a CSNP
snapshot S to region R, preserving canonical entity encodings.

1.5 Reconciliation Function (abstract)

reconcile : Policy x Input -> Either Error Snapshot

Where Input may be a set of CSPT sections, a CSNP snapshot, or a delta stream.
The invariants below apply to any concrete reconciliation algorithm.

---

2. Core Invariants (must hold for any compliant reconciler)

INV-1 Determinism
Given identical inputs, reconcile returns identical canonical bytes.
Formally:
  inputs1 == inputs2 => encodeSnapshot (reconcile inputs1) ==
                        encodeSnapshot (reconcile inputs2)

INV-2 Canonicality
Reconcile outputs are canonical CSNP snapshots.
Formally:
  reconcile inputs = Right S implies decodeSnapshot (encodeSnapshot S) == Right S

INV-3 Idempotence (Fixed Point)
Applying reconciliation to an already-reconciled snapshot is a no-op.
Formally:
  reconcile (reconcile inputs) == reconcile inputs

INV-4 Hash Law Preservation
The output hash is the SHA-256 of the output preimage, exactly as specified.
Formally:
  let bytes = encodeSnapshot S
  then hash(bytes[0:len-32]) == bytes[len-32:len]

INV-5 Overlap Agreement Safety
If CSPT inputs disagree on overlap, reconciliation must reject deterministically.
Formally:
  not agree(S1, S2) => reconcile {S1, S2, ...} == Left ErrOverlapMismatch
(Exact error type can be defined once the reconciler error model is fixed.)

INV-6 Sheaf Gluing (Existence and Uniqueness)
If a set of CSPT sections are pairwise agreeing and cover the target region,
then reconciliation returns the unique CSNP snapshot whose restriction to each
region equals the corresponding section.
Formally:
  agree(pairwise) and cover(regions) =>
    exists unique S such that for all i, restrict(S, Ri) == Si

---

3. Derived Invariants (strongly recommended)

INV-7 Projection to Canonical Space
Reconciliation acts as a projection onto canonical form.
Formally:
  encodeSnapshot (reconcile inputs) == encodeSnapshot (reconcile (canonicalize inputs))

INV-8 Monotone Repair (Policy-Dependent)
If reconciliation is defined as a repair operator on a lattice/closure:
  reconcile is monotone and convergent under repeated application.
Formally:
  inputs <= inputs' => reconcile(inputs) <= reconcile(inputs')
  and
  reconcile (reconcile inputs) == reconcile inputs

INV-9 Minimal Change (Policy-Dependent)
If a "patch" is produced, it must be minimal with respect to the policy order.
Formally:
  no other admissible patch produces a strictly smaller change while preserving
  admissibility.

---

4. Test Hooks (current and planned)

4.1 Existing Tests

- Canonicality + hash law are enforced by:
  test/GoldenSpec.hs
  test/PropertySpec.hs (hash_law_generated, encode_decode_roundtrip)

- Decoder totality for arbitrary bytes:
  test/PropertySpec.hs (decoder_totality, decoder_section_totality)

- Canonical projection invariants (partial):
  test/PropertySpec.hs (entity_permutation_invariant, nfc_type_equivalence,
                         negative_zero_component, duplicate_entity_rejected,
                         decoder_truncated_totality)

4.2 Reconciliation-Specific Tests (to add when reconciler exists)

- Overlap disagreement rejection:
  Construct two CSPT sections with conflicting entity bytes in overlap.
  Expect reconcile to return Left ErrOverlapMismatch.

- Sheaf gluing:
  Split a CSNP snapshot into disjoint CSPT sections, then reconcile them back.
  Expect canonical bytes to match the original CSNP.

- Determinism under permutation:
  Given a set of sections, any input order yields identical output bytes.

- Idempotence:
  reconcile output fed back as input yields identical bytes.

---

5. Notes on Error Modeling

The reconciliation error type is not defined in this repo yet. When it is:
- Introduce explicit error constructors for overlap mismatches and coverage gaps.
- Ensure errors are stable and deterministic (for use in distributed protocols).

---

6. Freeze Criteria

This document is intended to be frozen once:
- A concrete reconciliation algorithm exists in code.
- The tests in section 4.2 are implemented and passing.
- Error constructors and stability constraints are agreed.

---

7. Snapshot Canonical Layer Invariants (v1 Frozen)

These invariants are part of the snapshot v1 compliance contract and are enforced
by executable properties in `test/PropertySpec.hs` and `test/NormalizationSpec.hs`.
They define the canonical projection layer that all higher-level reconciliation
depends on.

S-1 Encoder Canonical Projection
Encoding a "dirty" snapshot (non-canonical inputs) is equal to encoding the
canonicalized snapshot.
Tests:
- `canonicalization_projection`

S-2 Idempotence (Encode/Decode Fixed Point)
Once canonical bytes are produced, re-decoding and re-encoding does not change them.
Tests:
- `snapshot_idempotent`
- `encode_decode_roundtrip`

S-3 NFC Normalization Invariance
NFC-equivalent entity/type strings encode to identical bytes.
Tests:
- `nfc_idempotent` (Normalization suite)
- `nfc_type_equivalence`

S-4 Float Canonicalization Invariance
Negative zero collapses to positive zero; NaN/Infinity are rejected.
Tests:
- `negative_zero_canonical` (Normalization suite)
- `negative_zero_component`
- `encoder_rejects_nan` (Normalization suite)

S-5 Permutation Invariance
Entity ordering does not affect canonical bytes.
Tests:
- `entity_permutation_invariant`

S-6 Hash Law
The trailing hash equals SHA-256 of the preimage.
Tests:
- `snapshot_hash`
- `hash_law_generated`
- Golden vectors in `test/GoldenSpec.hs`

S-7 Boundary Enforcement
Key length, string length, entity count, and component count bounds are enforced.
Tests:
- `key_length_max`, `key_length_over`
- `string_length_limit`, `string_length_over`
- `entity_count_limit`, `entity_count_over`
- `component_count_limit`, `component_count_over`
- `zero_length_string`, `zero_components`, `entity_id_edges`

S-8 Decoder Totality
Decoding arbitrary bytes or truncated canonical bytes never crashes.
Tests:
- `decoder_totality`, `decoder_section_totality`
- `decoder_truncated_totality`
