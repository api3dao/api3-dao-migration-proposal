# API3 DAO migration proposal

Everything behind the primary vote that moves API3 governance from the legacy DAO to Snapshot: the vote script, Foundry fork tests that run it through the real Aragon apps and check that the staking pool keeps working afterwards, and a decoder that prints the script as a table. Everything runs against a fork, nothing here broadcasts a transaction to mainnet.

## Prerequisites

[Foundry](https://getfoundry.sh), [bulloak](https://github.com/alexfertel/bulloak) and Node, then:

```bash
./setup.sh
```

The RPC is a rate limited mainnet archive endpoint in `foundry.toml`, shared by everyone who runs this, so nothing has to be configured. `--rpc-url <url>` on any forge or cast command, or `FOUNDRY_ETH_RPC_URL` for a whole session, overrides it.

## Running

```bash
# Check that a posted vote (e.g. "primary-17" in the DAO dashboard) is the proposal this code builds
forge script script/VerifyVote.s.sol --sig "run(uint256)" <VOTE_ID>

# The same when a balance moved between the build and the posting, <BUILD_BLOCK> is "block" in proposal/generated/amounts.json
forge script script/VerifyVote.s.sol --sig "run(uint256,uint256)" <VOTE_ID> <BUILD_BLOCK>

# Run the fork tests
./test.sh

# Run them on a posted vote's bytes, <BLOCK> is its snapshot block, or <BUILD_BLOCK> when the check above needed it
FOUNDRY_FORK_BLOCK_NUMBER=<BLOCK> ./test.sh

# Generate the proposal calldata for posting
forge script script/CreateVote.s.sol

# Print a vote script as a table
node scripts/decode-script.mjs <script.hex or 0x bytes>

# Rebuild the table below from the code at a block
node scripts/update-readme.mjs <block>
```

`test.sh` checks that every `.tree` matches its test file and runs the fork suite on the proposal the code builds at the latest block. Arguments go to `forge test`. [CI](.github/workflows/ci.yml) runs it and the table check on every pull request and push to `main`.

## What the vote does

One primary vote whose script makes the 26 calls below, in this order. Calls to the ACL and the primary Agent come from the primary voting app, everything else goes through the primary Agent's `execute`. The amounts are fixed at the block the script was built at and are unchanged when the vote is posted. The calls are the ones the proposal text lists. The secondary Agent's PNK and wPOKT are not among them: secondary votes 133 and 134, posted on 2026-10-27, move them to the agent multisig, so the primary vote does not depend on those two token contracts.

<!-- script-table -->

Built at block 26287968, 26 calls, 4316 bytes.

| # | caller | target | call |
| - | ------ | ------ | ---- |
| 1 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `grantPermission`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0`, TRANSFER_ROLE) |
| 2 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `grantPermission`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0`, EXECUTE_ROLE) |
| 3 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `transfer`(USDC `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48`, agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 59419713966 (59,419.713966 USDC)) |
| 4 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `execute`(agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 57118793443618210 wei (0.057118 ETH), no calldata) |
| 5 | voting app | primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae` | `transfer`(API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a`, Treasury Safe `0xb7fa2cb302c5dc127e61f27b92bec411cbf0ae4a`, 6083873527701856751553400 (6,083,873.527701 API3 token)) |
| 6 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(API3 pool `0x6dd655f10d4b9e242ae186d9050b68f725c76d76`, false) |
| 7 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, true) |
| 8 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `mint`(Treasury Safe `0xb7fa2cb302c5dc127e61f27b92bec411cbf0ae4a`, 10876876674326757910422715 (10,876,876.674326 API3 token)) |
| 9 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, false) |
| 10 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `transferOwnership`(dead address `0x000000000000000000000000000000000000dead`) |
| 11 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(any address `0xffffffffffffffffffffffffffffffffffffffff`, primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, CREATE_VOTES_ROLE) |
| 12 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(any address `0xffffffffffffffffffffffffffffffffffffffff`, secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, CREATE_VOTES_ROLE) |
| 13 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, CREATE_VOTES_ROLE) |
| 14 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, CREATE_VOTES_ROLE) |
| 15 | via primary Agent | primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b` | `changeSupportRequiredPct`(999999999999999999) |
| 16 | via primary Agent | primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b` | `changeMinAcceptQuorumPct`(999999999999999999) |
| 17 | via primary Agent | secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372` | `changeSupportRequiredPct`(999999999999999999) |
| 18 | via primary Agent | secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372` | `changeMinAcceptQuorumPct`(999999999999999999) |
| 19 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, MODIFY_SUPPORT_ROLE) |
| 20 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, MODIFY_QUORUM_ROLE) |
| 21 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, MODIFY_SUPPORT_ROLE) |
| 22 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, MODIFY_QUORUM_ROLE) |
| 23 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, Kernel `0x593ea926ee9820a933488b6a288433c387d06dba`, APP_MANAGER_ROLE) |
| 24 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(Kernel `0x593ea926ee9820a933488b6a288433c387d06dba`, APP_MANAGER_ROLE) |
| 25 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a`, CREATE_PERMISSIONS_ROLE) |
| 26 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a`, CREATE_PERMISSIONS_ROLE) |

The names next to the addresses are labels this decoder assigns for readability, they are not part of the script. The addresses are what the script holds, check them against the proposal.

<!-- /script-table -->

## What the tests assert

The tests follow the branching tree technique: each `.tree` file spells out what is checked, as conditions and the outcomes under them, and the `.t.sol` next to it has one test per branch, named after it. The vote is passed by real voting power, the holders in `test/data/voters.json`.

| tree                                       | what it checks                                                                                                                                      |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [test/vote/script.tree](test/vote/script.tree)     | the script's shape and count of 26 calls, calls routed to the ACL or the primary Agent, the metadata from the proposal files, a deployed Treasury Safe |
| [test/vote/execute.tree](test/vote/execute.tree)   | the outcome on both paths: supply exactly 200,000,000, the minter set final, the primary Agent's API3 and the secondary Agent's USDC and ETH in the multisigs, the Treasury Safe credited, the overshoot burned on the late path, a burn before execution left as it is |
| [test/dao/aragon.tree](test/dao/aragon.tree)       | the legacy voting apps after the migration: no new vote can be created, support and quorum at the maximum, the root permissions gone, even for the primary voting app itself |
| [test/pool/rewards.tree](test/pool/rewards.tree)   | `mintReward()` mints nothing after the migration, the total stake holds and the epoch cursor keeps advancing                                           |
| [test/pool/staking.tree](test/pool/staking.tree)   | staking and exits without new rewards: a full exit, locked rewards unlocking over 52 epochs, a new staker's round trip, a partial exit and re-entry over a year |
| [test/script/create-vote.tree](test/script/create-vote.tree) | generated monetary amounts remain exact decimal strings, including ETH above JavaScript's safe integer limit |

## Creating and verifying the proposal

[script/CreateVote.s.sol](script/CreateVote.s.sol) generates the proposal calldata from the chain state at the current block, ready to be submitted by the Vault Safe to the Aragon voting contract, and prints where it wrote it. Nothing is sent.

Monetary amounts in `proposal/generated/amounts.json` are decimal strings to preserve every base unit in JavaScript. The block remains a JSON number.

[script/VerifyVote.s.sol](script/VerifyVote.s.sol) checks a posted vote, `<VOTE_ID>` being the number in its DAO dashboard URL, `primary-<VOTE_ID>`: it rebuilds the proposal from this code at the vote's snapshot block and compares it with the vote on the chain, the script, the metadata and the Vault Safe as the creator. Read-only.

The bytes carry four balances read when they were built: the mint, the primary Agent's API3, the secondary Agent's USDC and its ETH. One wei of API3 burned, or of USDC or ETH sent to the secondary Agent, between the build and the posting changes what the code builds at the snapshot block and fails the check above, although the vote is still exactly what the code built. The second form takes the block the bytes were built at, `block` in the `proposal/generated/amounts.json` that `CreateVote.s.sol` wrote, rebuilds the proposal there, and prints which of the four amounts moved between the build and the posting and by how much. Read-only as well.
