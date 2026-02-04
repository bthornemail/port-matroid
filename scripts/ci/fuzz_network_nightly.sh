#!/usr/bin/env bash
set -euo pipefail

cd port-matroid
NETWORK_FUZZ_MAX="${NETWORK_FUZZ_MAX:-5000}" \
NETWORK_FUZZ_STEPS="${NETWORK_FUZZ_STEPS:-500}" \
cabal test network-fuzz --test-show-details=direct
