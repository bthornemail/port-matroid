#!/usr/bin/env bash
set -euo pipefail

cd port-matroid
NETWORK_FUZZ_MAX="${NETWORK_FUZZ_MAX:-100}" \
NETWORK_FUZZ_STEPS="${NETWORK_FUZZ_STEPS:-50}" \
cabal test network-fuzz --test-show-details=direct
