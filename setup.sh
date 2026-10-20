#!/bin/bash
# Fetches forge-std, and the DAO dashboard for the vote preview. Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"
# The dashboard commit the preview was last checked against, on its `multi-call-proposals` branch until that is
# upstream. The checkout is a plain clone, switch branches in it as needed.
DASHBOARD_COMMIT=172a38bc40eb4d058c3ff0f1c07d8e7f3938309b
# Pinned, so that everyone who rebuilds the bytes compiles against the same library.
FORGE_STD_TAG=v1.17.0
if [ ! -d lib/forge-std ]; then
  mkdir -p lib
  git -c advice.detachedHead=false clone --depth 1 --branch "$FORGE_STD_TAG" --quiet https://github.com/foundry-rs/forge-std lib/forge-std
  rm -rf lib/forge-std/.git
fi
if [ ! -d api3-dao-dashboard ]; then
  git clone --quiet https://github.com/api3dao/api3-dao-dashboard.git api3-dao-dashboard
  git -C api3-dao-dashboard checkout --quiet "$DASHBOARD_COMMIT"
fi
[ -n "${ETH_RPC_URL:-}" ] || echo "set ETH_RPC_URL to a mainnet RPC before running forge"
echo ready
