#!/bin/bash
# Runs the DAO dashboard against a mainnet fork on which the Vault Safe has posted the vote, to see how the proposal
# renders before it is posted for real. anvil forks mainnet, the vote exists only on the fork, nothing here touches
# mainnet.
#
# Needs anvil, forge, cast and pnpm, and a mainnet RPC in ETH_RPC_URL. The dashboard checkout is ./api3-dao-dashboard
# (setup.sh clones it), DASHBOARD_DIR overrides it. The ports default to 57751 for anvil and 57750 for the dashboard,
# ANVIL_PORT and DASHBOARD_PORT override them.
#
# Open the dashboard in a browser profile without a wallet extension: in development mode it then connects by itself
# as the first anvil account. With a wallet extension, add a network with chain id 31337 and the anvil URL, and connect
# through it. Either way the dashboard reads the fork through the hardhat network entry, whose addresses are the
# mainnet ones. The dashboard shows a proposal created outside of it only when it knows the script's hash, which the
# generated .env passes for this fork's vote.
set -euo pipefail
cd "$(dirname "$0")"
ANVIL_PORT=${ANVIL_PORT:-57751}
DASHBOARD_PORT=${DASHBOARD_PORT:-57750}
DASHBOARD_DIR=${DASHBOARD_DIR:-./api3-dao-dashboard}
FORK_URL=${ETH_RPC_URL:?set ETH_RPC_URL to a mainnet RPC}
VAULT=0x8e03609ed680B237C7b6f8020472CA0687308b24
TREASURY_SAFE=0x00000000000000000000000000000000DeaDBeef
ANVIL_URL=http://127.0.0.1:$ANVIL_PORT

[ -d "$DASHBOARD_DIR/node_modules" ] || pnpm -C "$DASHBOARD_DIR" install --frozen-lockfile

anvil --fork-url "$FORK_URL" --chain-id 31337 --port "$ANVIL_PORT" --auto-impersonate --silent &
ANVIL_PID=$!
# Whatever ends this script also ends anvil and the dashboard
trap 'kill $ANVIL_PID 2>/dev/null; lsof -ti:"$DASHBOARD_PORT" -sTCP:LISTEN 2>/dev/null | xargs -r kill' EXIT
until cast block-number --rpc-url "$ANVIL_URL" >/dev/null 2>&1; do sleep 1; done
echo "anvil forked mainnet at block $(cast block-number --rpc-url "$ANVIL_URL"), chain id 31337, on $ANVIL_URL"

# Gas for the Vault Safe, which anvil impersonates
cast rpc anvil_setBalance "$VAULT" 0x56BC75E2D63100000 --rpc-url "$ANVIL_URL" >/dev/null
# CreateVote refuses a Treasury Safe without code, which the placeholder in the source has none of until the Safe
# is created. On the fork a stop opcode stands in for it, nothing in the vote calls the Safe.
if [ "$(cast code "$TREASURY_SAFE" --rpc-url "$ANVIL_URL")" = 0x ]; then
  cast rpc anvil_setCode "$TREASURY_SAFE" 0x00 --rpc-url "$ANVIL_URL" >/dev/null
fi
forge script script/CreateVote.s.sol --rpc-url "$ANVIL_URL" --broadcast --unlocked --sender "$VAULT" -vv
VOTE_ID=$(cat proposal/generated/vote-id.txt)

cat > "$DASHBOARD_DIR/.env" <<EOF
# Written by dashboard-preview.sh, points the dashboard at the anvil fork and names this fork's vote script
VITE_NODE_ENV=development
VITE_PROJECT_ID=8bddccf51318f114759f31306090233e
VITE_MAINNET_PROVIDER_URL=http://localhost:$ANVIL_PORT
VITE_HARDHAT_PROVIDER_URL=http://localhost:$ANVIL_PORT
VITE_MULTI_CALL_SCRIPT_HASH=$(cat proposal/generated/script-hash.txt)
EOF

echo
echo "vote $VOTE_ID is posted on the fork, open http://localhost:$DASHBOARD_PORT/#/governance/primary-$VOTE_ID"
echo
pnpm -C "$DASHBOARD_DIR" start --port "$DASHBOARD_PORT" --strictPort
