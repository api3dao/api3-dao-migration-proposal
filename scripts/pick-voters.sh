#!/bin/bash
# Builds test/data/voters.json: addresses whose combined voting power passes a primary vote, plus
# stakers with locked rewards for the unstake tests.
#
# Candidates are every past CastVote voter, the 150 largest stakers by their latest Staked event,
# and the delegates of both. They are ranked by userVotingPower at FORK_BLOCK (default: latest)
# and taken greedily until they hold 75% of all shares, so the set keeps passing the 50% bar for
# a while as stakes drift.
#
# Needs forge, cast, curl, jq and python3. Read-only, against ETH_RPC_URL or the endpoint in foundry.toml.
set -euo pipefail
cd "$(dirname "$0")/.."
ETH_RPC_URL=${ETH_RPC_URL:-$(forge config --json | jq -r .eth_rpc_url)}
FORK_BLOCK=${FORK_BLOCK:-$(cast block-number --rpc-url "$ETH_RPC_URL")}
POOL_DEPLOY_BLOCK=12800000
POOL=0x6dd655f10d4b9e242ae186d9050b68f725c76d76
VOTING=0xdb6c812e439ce5c740570578681ea7aadba5170b
OUT=test/data/voters.json
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

get_logs() { # address topic0 from to -> raw JSON-RPC result, retried
  local r
  for try in 1 2 3 4 5 6; do
    r=$(curl -s -m 40 "$ETH_RPC_URL" -H 'content-type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getLogs\",\"params\":[{\"address\":\"$1\",\"topics\":[\"$2\"],\"fromBlock\":\"$(printf 0x%x "$3")\",\"toBlock\":\"$(printf 0x%x "$4")\"}]}")
    if echo "$r" | jq -e .result >/dev/null 2>&1; then echo "$r"; return 0; fi
    sleep $((try * 3))
  done
  echo "eth_getLogs failed for $3-$4" >&2
  return 1
}
export -f get_logs
export ETH_RPC_URL POOL WORK

echo "1/3 CastVote events of every primary vote"
CAST_VOTE=$(cast keccak "CastVote(uint256,address,bool,uint256)")
n=$(cast call "$VOTING" 'votesLength()(uint256)' --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1)
: > "$WORK/voters.txt"
for ((i = 0; i < n; i++)); do
  snap=$(cast call "$VOTING" 'getVote(uint256)(bool,bool,uint64,uint64,uint64,uint64,uint256,uint256,uint256,bytes)' "$i" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | sed -n 4p | cut -d' ' -f1)
  for ((from = snap; from < snap + 60000; from += 10000)); do
    get_logs "$VOTING" "$CAST_VOTE" "$from" $((from + 9999)) | jq -r '.result[] | "0x" + .topics[2][26:]' >> "$WORK/voters.txt"
  done
done

echo "2/3 Staked events since pool deployment"
STAKED=$(cast keccak "Staked(address,uint256,uint256,uint256,uint256,uint256,uint256)")
export STAKED
seq "$POOL_DEPLOY_BLOCK" 10000 "$FORK_BLOCK" | xargs -P 6 -I{} bash -c '
  f={}; t=$((f + 9999)); [ $t -gt '"$FORK_BLOCK"' ] && t='"$FORK_BLOCK"'
  get_logs "$POOL" "$STAKED" $f $t | jq -r ".result[] | [(.blockNumber | ltrimstr(\"0x\") | ascii_downcase), (\"0x\" + .topics[1][26:]), .data[2 + 64 * 3:2 + 64 * 4]] | @tsv" >> "$WORK/staked.$f.tsv"
'
cat "$WORK"/staked.*.tsv > "$WORK/staked.tsv"
sort -k1,1 "$WORK/staked.tsv" | awk -F'\t' '{last[$2] = $3} END {for (u in last) print u "\t" last[u]}' \
  | python3 -c 'import sys; rows = sorted(((l.split("\t")[0], int(l.split("\t")[1], 16)) for l in sys.stdin if "\t" in l), key=lambda r: -r[1]); print("\n".join(r[0] for r in rows[:150]))' >> "$WORK/voters.txt"
sort -u "$WORK/voters.txt" -o "$WORK/candidates.txt"
for a in $(cat "$WORK/candidates.txt"); do
  cast call "$POOL" 'userDelegate(address)(address)' "$a" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK"
done | grep -v -i 0x0000000000000000000000000000000000000000 | tr 'A-F' 'a-f' >> "$WORK/candidates.txt" || true
sort -u "$WORK/candidates.txt" -o "$WORK/candidates.txt"

echo "3/3 ranking $(wc -l < "$WORK/candidates.txt") candidates by voting power at block $FORK_BLOCK"
: > "$WORK/ranked.tsv"
for a in $(cat "$WORK/candidates.txt"); do
  vp=$(cast call "$POOL" 'userVotingPower(address)(uint256)' "$a" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1)
  st=$(cast call "$POOL" 'userStake(address)(uint256)' "$a" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1)
  lk=$(cast call "$POOL" 'userLocked(address)(uint256)' "$a" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1)
  u=$(cast call "$POOL" 'getUser(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$a" --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1 | tr '\n' ' ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$vp" "$st" "$lk" "$(echo $u | cut -d' ' -f2)" "$(echo $u | cut -d' ' -f5)" >> "$WORK/ranked.tsv"
done
total=$(cast call "$POOL" 'totalShares()(uint256)' --rpc-url "$ETH_RPC_URL" --block "$FORK_BLOCK" | cut -d' ' -f1)
python3 - "$WORK/ranked.tsv" "$total" "$OUT" "$FORK_BLOCK" <<'PY'
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
total, out, block = int(sys.argv[2]), sys.argv[3], sys.argv[4]
rows = sorted(((r[0], int(r[1]), int(r[2]), int(r[3]), int(r[4]), int(r[5])) for r in rows), key=lambda r: -r[1])
voters, cum = [], 0
for a, vp, *_ in rows:
    if vp == 0:
        continue
    voters.append(a)
    cum += vp
    if cum * 100 / total >= 75:
        break
stakers = [a for a, vp, st, lk, vest, sched in rows if st > 0 and lk > 0 and sched == 0 and vest == 0][:10]
print(f"voters={len(voters)} holding {cum * 100 / total:.1f}% of all shares, stakers={len(stakers)}")
json.dump({"forkBlock": int(block), "voters": voters, "stakers": stakers}, open(out, "w"), indent=2)
PY
echo "wrote $OUT"
