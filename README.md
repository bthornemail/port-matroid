# port-matroid

## Compliance Appendix (v1)

An implementation is compliant if it passes all of the following suites:

1. Snapshot law
- `cabal test golden`
- `cabal test property`
- `cabal test normalization`

2. Instruction law
- `cabal test instruction-golden`
- `cabal test instruction-stream-golden`
- `cabal test halt-golden`
- `cabal test universe`

3. Replay contract
- `cabal test replay`

Frozen Consensus Specifications (v1)

The following documents define consensus-critical behavior.
Implementations must match them byte-for-byte and error-for-error.

snapshot-law-v1
Canonical snapshot encoding + hash law
-> `dev-docs/SNAPSHOT-FORMAT.md`

universe-isa-v1
Instruction set semantics + halt model
-> `dev-docs/UNIVERSE-ISA.md`

universe-replay-v1
Replay contract + prefix execution law
-> instruction stream + replay tests

reconcile-law-v1
Section reconciliation + error priority model
-> `dev-docs/RECONCILIATION-INVARIANTS.md`

Any divergence from these specifications is a consensus fork.

Architecture reference:
- `dev-docs/UNIVERSE-ARCHITECTURE.md`
