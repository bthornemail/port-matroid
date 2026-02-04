#!/usr/bin/env bash
set -euo pipefail

cd port-matroid
STORAGE_FUZZ_MAX="${STORAGE_FUZZ_MAX:-200}" \
STORAGE_FUZZ_MAX_SMALL="${STORAGE_FUZZ_MAX_SMALL:-100}" \
cabal test storage-fuzz --test-show-details=direct
