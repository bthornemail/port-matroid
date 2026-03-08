# Testing And Compliance Map

## Why This Matters

This repository treats tests as executable protocol contracts.
Contributor changes should be described in terms of which law/invariant suite they affect.

## Suite-To-Law Mapping

Snapshot and canonical encoding law:

- `golden`
- `property`
- `normalization`

Universe / instruction law:

- `instruction-golden`
- `instruction-stream-golden`
- `halt-golden`
- `universe`

Replay contract:

- `replay`

Reconciliation law:

- `reconcile`
- `reconcile-error-golden`

Scheduler law:

- `scheduler-golden`
- `scheduler-property`
- `scheduler-error-golden`

Routing law:

- `routing-golden`
- `routing-error-golden`
- `routing-bad`

Convergence and union laws:

- `convergence`
- `union-law`
- `convergence-sim`

Scheduler-network law:

- `network-digest-golden`
- `network-authority`
- `network-epoch`
- `network-bad`
- `network-state`

Fuzz / durability behavior:

- `network-fuzz`
- `storage-fuzz`

Seam boundary contract:

- `seam-producer`

## Current Harness Caveat

Observed in current test executables:

- Some QuickCheck properties print failure lines (for example `*** Failed!`) while the suite still exits `PASS`.
- This happens because several suites run `quickCheckWith` without converting failures into process failure.

Practical impact:

- CI can report green while specific properties falsify during output.
- Contributors must read logs for property-level failures, not only suite exit status.

## Contributor Workflow

Before submitting behavior changes:

1. Run targeted suites for touched subsystem(s).
2. Run `cabal test all --test-show-details=direct`.
3. Inspect output/logs for QuickCheck falsifications even when final suite status is `PASS`.
4. Add or update golden fixtures when byte-level contracts intentionally change.
5. Update docs in `docs/` and relevant frozen `dev-docs/` file when protocol intent changes.

## Recommended Hardening Follow-Up

Future maintenance work should make property suites fail fast on falsification (for example by using `quickCheckWithResult` and explicit non-success exit), so suite status matches property outcomes.

