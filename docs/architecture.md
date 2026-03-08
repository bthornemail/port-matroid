# Architecture For Contributors

## Metastructure Preface

The project can be read as a layered metastructure where logical orders inhabit shared invariants:

- Type theory / axioms anchor admissibility.
- Boundaries / BICF / rule engines / constraints govern interaction.
- Geometry provides continuity, duality, and dimensional partitioning.
- Hypergraph-like structure organizes distributed work and dependency shape.
- Provenance gives temporal lawful composition.
- Federation gives multi-agent distributed semantics.
- Projection surfaces expose observable execution.

These are not alternatives to logic levels (propositional, first-order, second-order, higher-order, grammar, concurrent-constraint, rule-engine forms). They are the architecture that hosts them.

## Boundary Statement

For contributors, this preface is a systems interpretation.
Consensus-critical behavior remains defined by executable code and tests in this repository, with frozen protocol docs in `dev-docs/` as normative intent.

## Constitutional Basis

### Type/Axiom Admissibility

Concrete implementation:

- `Snapshot.Decode` and `Snapshot.Encode` enforce canonical forms, ordering, UTF-8/NFC checks, key/value constraints, float rules, and hash law.
- `Snapshot.Errors` codifies structured decoder/encoder failures.
- `Snapshot.Universe.Core` enforces instruction framing, opcode semantics, halt model, and authority gates.

Executable checks:

- `golden`, `property`, `normalization`, `instruction-golden`, `instruction-stream-golden`, `halt-golden`, `universe`, `replay`.

### Boundaries / BICF Interaction Layer

Concrete implementation:

- `Snapshot.Universe.Core` instruction semantics and authority boundaries.
- `Snapshot.Scheduler.Validate` and `Snapshot.Scheduler.Core` workset admissibility and deterministic scheduling limits.
- Seam envelope boundary validation in `app/port-matroid-tool/Main.hs` (`append-envelope`, schema fail-closed checks, producer-prefix rules).

Executable checks:

- `scheduler-golden`, `scheduler-property`, `scheduler-error-golden`, `seam-producer`.

## Structural Basis

### Geometry

The implemented geometry is operational, not symbolic:

- Scheduler cell coordinates (`shard`, tick range, entity range, tier) define legal space for work partitioning.
- Reconciliation regions (`Snapshot.Reconcile.Types`) enforce compatibility and range discipline.

### Hypergraph-Like Structure

Concrete implementation:

- Work items, touch sets, and conflict relations in `Snapshot.Scheduler.Validate` + `Snapshot.Scheduler.Core`.
- Union and convergence primitives in `Snapshot.Scheduler.Union` and `Snapshot.Scheduler.Network.Sim`.

Executable checks:

- `reconcile`, `reconcile-error-golden`, `convergence`, `convergence-sim`, `union-law`.

## Historical / Distributed Basis

### Provenance

Concrete implementation:

- WAL append/replay/checksum/header invariants and manifest generation in `Runtime.Store`.
- Envelope digest index and provenance TSV generation/verification in `port-matroid-tool`.

### Federation

Concrete implementation:

- Routing context validation and deterministic replica assignment (`Snapshot.Routing.*`).
- Scheduler-network message canonicality and digest authority checks (`Snapshot.Scheduler.Network.*`).
- Runtime gossip pull behavior for snapshot/WAL anti-entropy (`Runtime.Net.Gossip*`).

Executable checks:

- `routing-golden`, `routing-error-golden`, `routing-bad`,
- `network-digest-golden`, `network-authority`, `network-epoch`, `network-bad`, `network-state`, `network-fuzz`.

## Observable Basis (Projection Surfaces)

Current execution surfaces:

- `snapshot-verify`: verifies `.csnp` or `.cspt`.
- `port-matroidd`: daemon loop combining server, control socket, scheduler tick, WAL/snapshot persistence.
- `port-matroidctl`: framed control-socket client.
- `port-matroid-tool`: offline validation/audit/envelope/provenance utilities.

These are the projection interfaces where invariant-preserving internals become inspectable or operable.

