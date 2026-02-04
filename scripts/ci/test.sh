#!/usr/bin/env bash
set -euo pipefail

cd port-matroid
cabal test all --test-show-details=direct
