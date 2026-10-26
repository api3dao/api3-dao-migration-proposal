#!/bin/bash
# The test command: checks that every .tree still matches its test file with bulloak, then runs the fork suite.
# Arguments go to `forge test`, so `./test.sh -vv` or `./test.sh --match-path 'test/vote/*'` work, and so do the
# environment variables the suite reads (GENERATED_DIR, FOUNDRY_ETH_RPC_URL).
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v bulloak >/dev/null; then
  echo "bulloak is missing: cargo install bulloak, or a binary from https://github.com/alexfertel/bulloak/releases" >&2
  exit 1
fi
bulloak check test/*/*.tree
forge test "$@"
