#!/bin/bash
# Fetches forge-std. Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"
# Pinned, so that everyone who rebuilds the bytes compiles against the same library.
FORGE_STD_TAG=v1.17.0
if [ ! -d lib/forge-std ]; then
  mkdir -p lib
  git -c advice.detachedHead=false clone --depth 1 --branch "$FORGE_STD_TAG" --quiet https://github.com/foundry-rs/forge-std lib/forge-std
  rm -rf lib/forge-std/.git
fi
echo ready
