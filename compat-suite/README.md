# ulp-compat-suite

Compatibility suite for ULP constitutional invariants.

## Contents
- `fixtures/events/`   Golden trace/event fixtures
- `fixtures/snapshots/` Canonical snapshot fixtures
- `fixtures/manifests/` Manifest fixtures
- `schema/`            JSON schema mirrors
- `scripts/`           Determinism and compatibility runners

## Required checks
- Golden decode/encode round-trips
- Canonical hash validation
- Must-reject corpus
- Schema compatibility

## Usage (placeholder)
```
./scripts/run.sh
```

## Fixtures
- `fixtures/events/*.ndjson`: must-accept event traces (hashes validate)
- `fixtures/events/bad/*.ndjson`: must-reject event traces (hash mismatch expected)
- `fixtures/segments/accept/*.ndjson`: must-accept trace segments (anchored windows between checkpoints)
- `fixtures/segments/bad/*.ndjson`: must-reject trace segments (anchor/chain/checkpoint mismatch)
- `fixtures/manifests/*.txt`: must-accept manifests (CRC validates if present)
- `fixtures/manifests/bad/*.txt`: must-reject manifests (unknown/missing keys or CRC mismatch)
