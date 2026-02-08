#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP="$ROOT/test/golden/one-entity.csnp"
EXPECTED_HASH_FILE="$ROOT/test/golden/one-entity.hash"

cd "$ROOT"

if [ ! -f "$SNAP" ]; then
  echo "missing snapshot fixture: $SNAP" >&2
  exit 1
fi

# 1) Validate canonical snapshot (kernel decode)
(cabal -v0 run snapshot-verify -- "$SNAP" >/dev/null)

# 2) Deterministic derived output (projector stub = hash)
HASH1=$(python3 - <<PY
import hashlib
from pathlib import Path
p = Path("$SNAP")
data = p.read_bytes()
if len(data) < 32:
    raise SystemExit("file too small for hash")
preimage = data[:-32]
print(hashlib.sha256(preimage).hexdigest())
PY
)
HASH2=$(python3 - <<PY
import hashlib
from pathlib import Path
p = Path("$SNAP")
data = p.read_bytes()
if len(data) < 32:
    raise SystemExit("file too small for hash")
preimage = data[:-32]
print(hashlib.sha256(preimage).hexdigest())
PY
)

if [ "$HASH1" != "$HASH2" ]; then
  echo "nondeterministic hash" >&2
  exit 1
fi

if [ -f "$EXPECTED_HASH_FILE" ]; then
  EXPECTED=$(cat "$EXPECTED_HASH_FILE" | tr -d '\n')
  if [ "$HASH1" != "$EXPECTED" ]; then
    echo "hash mismatch: expected $EXPECTED got $HASH1" >&2
    exit 1
  fi
fi

echo "ok thin-slice demo: snapshot valid, deterministic hash=$HASH1"
