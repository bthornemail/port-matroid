#!/usr/bin/env bash
set -euo pipefail

cd port-matroid
cabal update
cabal build all --enable-tests
