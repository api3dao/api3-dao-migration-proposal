# API3 DAO migration proposal

Everything behind the primary vote that winds down the Aragon-based API3 DAO and moves governance to Snapshot: the vote script, Foundry fork tests that run it through the real Aragon apps and check that the staking pool keeps working afterwards and a decoder that prints the script as a table. Everything runs against a fork, nothing here broadcasts a transaction to mainnet.

## Running

Needs [Foundry](https://getfoundry.sh), [bulloak](https://github.com/alexfertel/bulloak) and Node. The RPC is a rate limited mainnet archive endpoint in `foundry.toml`, shared by everyone who runs this, so nothing has to be configured. `--rpc-url <url>` on any forge or cast command, or `FOUNDRY_ETH_RPC_URL` for a whole session, overrides it.

```bash
./setup.sh
./test.sh
```

`test.sh` checks that every `.tree` still matches its test file and runs the fork suite on the script the source builds at the latest block. Arguments go to `forge test`. [CI](.github/workflows/ci.yml) runs the same on every pull request and push to `main`, plus the suite on the committed bytes and the README table check, see below.

## What the vote does

One primary vote whose script makes the 28 calls below, in this order. Calls to the ACL and the primary Agent come from the primary voting app, everything else goes through the primary Agent's `execute`. The table is the committed bytes, [proposal/generated/script.hex](proposal/generated/script.hex), decoded by `node scripts/update-readme.mjs`, and CI fails when it is out of date. The amounts are the balances at the block the bytes were built at, rebuilt right before posting.

<!-- script-table -->

Built at block 26274256 ([proposal/generated/amounts.json](proposal/generated/amounts.json)), 28 calls, 4884 bytes.

| # | caller | target | call |
| - | ------ | ------ | ---- |
| 1 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `grantPermission`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0`, TRANSFER_ROLE) |
| 2 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `grantPermission`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0`, EXECUTE_ROLE) |
| 3 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `transfer`(USDC `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48`, agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 59419713966 (59,419.713966 USDC)) |
| 4 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `transfer`(PNK `0x93ed3fbe21207ec2e8f2d3c3de6e058cb73bc04d`, agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 1547987000000000000000000 (1,547,987.000000 PNK)) |
| 5 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `transfer`(wPOKT `0x67f4c72a50f8df6487720261e188f2abe83f57d7`, agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 249999990000 (249,999.990000 wPOKT)) |
| 6 | via primary Agent | secondary Agent `0x556ecbb0311d350491ba0ec7e019c354d7723ce0` | `execute`(agent multisig `0xbbe0de9757f93e3306adbfebe906ab285edd13da`, 57118793443618210 wei (0.057118 ETH), no calldata) |
| 7 | voting app | primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae` | `transfer`(API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a`, Treasury Safe `0xb7fa2cb302c5dc127e61f27b92bec411cbf0ae4a`, 6083873527701856751553400 (6,083,873.527701 API3 token)) |
| 8 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(Api3Pool `0x6dd655f10d4b9e242ae186d9050b68f725c76d76`, false) |
| 9 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, true) |
| 10 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `mint`(Treasury Safe `0xb7fa2cb302c5dc127e61f27b92bec411cbf0ae4a`, 10876876674326757910422715 (10,876,876.674326 API3 token)) |
| 11 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `updateMinterStatus`(primary Agent `0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae`, false) |
| 12 | via primary Agent | API3 token `0x0b38210ea11411557c13457d4da7dc6ea731b88a` | `transferOwnership`(dead address `0x000000000000000000000000000000000000dead`) |
| 13 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(any address `0xffffffffffffffffffffffffffffffffffffffff`, primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, CREATE_VOTES_ROLE) |
| 14 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(any address `0xffffffffffffffffffffffffffffffffffffffff`, secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, CREATE_VOTES_ROLE) |
| 15 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, CREATE_VOTES_ROLE) |
| 16 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, CREATE_VOTES_ROLE) |
| 17 | via primary Agent | primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b` | `changeSupportRequiredPct`(999999999999999999) |
| 18 | via primary Agent | primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b` | `changeMinAcceptQuorumPct`(999999999999999999) |
| 19 | via primary Agent | secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372` | `changeSupportRequiredPct`(999999999999999999) |
| 20 | via primary Agent | secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372` | `changeMinAcceptQuorumPct`(999999999999999999) |
| 21 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, MODIFY_SUPPORT_ROLE) |
| 22 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, MODIFY_QUORUM_ROLE) |
| 23 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, MODIFY_SUPPORT_ROLE) |
| 24 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(secondary voting app `0x1c8058e72e4902b3431ef057e8d9a58a73f26372`, MODIFY_QUORUM_ROLE) |
| 25 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, Kernel `0x593ea926ee9820a933488b6a288433c387d06dba`, APP_MANAGER_ROLE) |
| 26 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(Kernel `0x593ea926ee9820a933488b6a288433c387d06dba`, APP_MANAGER_ROLE) |
| 27 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `revokePermission`(primary voting app `0xdb6c812e439ce5c740570578681ea7aadba5170b`, ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a`, CREATE_PERMISSIONS_ROLE) |
| 28 | voting app | ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a` | `removePermissionManager`(ACL `0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a`, CREATE_PERMISSIONS_ROLE) |

<!-- /script-table -->

The script follows Appendix A of the proposal text, row by row:

1. ACL: grant the primary Agent `TRANSFER_ROLE` and `EXECUTE_ROLE` on the secondary Agent. Aragon's Vault sends ETH with `send`, and the 2300 gas stipend is not enough for a Safe to receive it (`VAULT_SEND_REVERTED` on the fork), so the ETH in row 2 goes through `execute`, which needs the second role. The primary voting app manages that role too, so no other vote is needed.
2. Secondary Agent: transfer its USDC, PNK and wPOKT to the agent multisig, and its ETH through `execute`. The amounts are read from the chain when the script is built, right before posting.
3. Primary Agent: transfer its API3 to the Treasury Safe, see below.
4. Token: revoke the pool's minter status. Rewards stop.
5. Token: grant the primary Agent minter status.
6. Token: mint the remainder to 200,000,000 API3 into the Treasury Safe.
7. Token: revoke the primary Agent's minter status.
8. Token: transfer ownership to `0x000000000000000000000000000000000000dEaD`. `Api3Token.renounceOwnership()` reverts by design, so this is the only way to freeze the minter set.
9. ACL: revoke the right of any address to create votes on both voting apps.
10. ACL: remove the manager of that right on both apps, so nobody can grant it again.
11. Both voting apps: raise support and quorum to the contract maximum, support first because the app rejects a quorum above the support, then remove the managers of both roles on both apps.
12. ACL: revoke the primary voting app's `CREATE_PERMISSIONS_ROLE` on the ACL and `APP_MANAGER_ROLE` on the Kernel, and remove both managers. These are the DAO's root permissions, both held and managed by the primary voting app. Removing a permission's manager, as rows 10 and 11 do, is what lets a holder of `CREATE_PERMISSIONS_ROLE` create that permission again, and `APP_MANAGER_ROLE` swaps the code behind any app. Rows 9 and 10 already put both out of reach, since only a primary vote could use them. This row makes that hold even for a vote created through a route not seen, or one still open at execution.

The Treasury Safe is a new Safe for the API3 the vote moves. It only holds, with the same signers as the Vault and Agent Safes, which execute what passes, and it never votes on Snapshot. The Vault Safe, which many pool delegations name, votes there with that delegated stake, its own API3 moving to the Treasury Safe right after execution, so the treasury's weight stays out of its hands. It is `0xb7fa2Cb302C5dC127e61F27b92beC411cbf0AE4A`, 3 of 5 with the same signers, and its Snapshot voting power is delegated to the dead address. `CreateVote.s.sol` and the file mode of the tests check that the address has code.

The mint amount is fixed when the script is built. A primary vote can execute the moment yea exceeds 50% of all voting power, and the intended path executes it there, before the next weekly reward mint, so the supply lands on exactly 200,000,000 with nothing to burn. The fallback path is rehearsed too: one more epoch is minted before execution, about 0.95M API3 at the current APR, and the Treasury Safe, which received the mint, burns the overshoot with `burn(excess)`, having registered as a burner with `updateBurnerStatus(true)` before the vote opened.

## What the tests assert

The tests follow the branching tree technique: each `.tree` file spells out what is checked, as conditions and the outcomes under them, and the `.t.sol` next to it has one test per branch, named after it. The vote is passed by real voting power, the holders in `test/data/voters.json`.

| tree                                       | what it checks                                                                                                                                      |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [test/vote/script.tree](test/vote/script.tree)     | the bytes: the CallsScript shape and its 28 calls, every call on the ACL or the primary Agent, version 3 metadata, and the committed files against the source |
| [test/vote/execute.tree](test/vote/execute.tree)   | the outcome on both paths: supply exactly 200,000,000, the token frozen, both agents emptied into the multisigs, the Treasury Safe credited, the overshoot burned on the late path, a burn before execution left as it is |
| [test/dao/closed.tree](test/dao/closed.tree)       | the old DAO after the vote: no vote can be created, support and quorum at the maximum, the root permissions gone, even for the primary voting app itself |
| [test/pool/rewards.tree](test/pool/rewards.tree)   | `mintReward()` mints nothing after the shutdown, the total stake holds and the epoch cursor keeps advancing                                           |
| [test/pool/staking.tree](test/pool/staking.tree)   | stakers keep every right but voting: a full exit, locked rewards unlocking over 52 epochs, a new staker's round trip, a partial exit and re-entry over a year |

## Proposal creation

The vote is created programmatically, not through the DAO dashboard. [script/CreateVote.s.sol](script/CreateVote.s.sol) builds the script and the metadata string from the chain state at the current block and writes them to `proposal/generated/`, which is committed, and the Vault Safe posts exactly those bytes with `newVote(script, metadata, false, false)`. The title and description of the vote are [proposal/title.txt](proposal/title.txt) and [proposal/description.md](proposal/description.md), joined into the DAO dashboard's metadata scheme version 3 (`3`, title, description without the file's trailing newline, separated by `0x1f`), the version the dashboard decodes from the script alone.

```bash
forge script script/CreateVote.s.sol
node scripts/update-readme.mjs
```

The first command writes `script.hex`, `script-hash.txt` (its keccak256, which the dashboard has to know to show the proposal), `metadata.txt` and `amounts.json` with the block the amounts were read at. Nothing is sent, the `newVote` call is only simulated, which checks that the Vault Safe clears the proposal threshold. The second rewrites the table above from the new bytes. Every amount has to be positive when the bytes are built, Aragon's Vault refuses a zero transfer and one reverting call reverts the whole script, so a row with nothing left to move has to be dropped from the script instead.

Both the files and the posted vote can be verified programmatically, see the next section. `node scripts/decode-script.mjs <script.hex or 0x bytes>` prints any CallsScript as the table above, with the roles, addresses and amounts named, and anything it does not recognise raw.

## Verify it yourself

Everything below is read-only and needs no account. Three checks, one per link of the chain from the source to the vote on the chain:

1. **The source.** `forge test` builds the script from [src/ShutdownScript.sol](src/ShutdownScript.sol) at the latest block and runs the suite on it. This is what the bytes are supposed to be.

2. **The committed files.** `GENERATED_DIR=proposal/generated forge test` reads `script.hex`, `metadata.txt`, `amounts.json` and `script-hash.txt` instead, rolls the fork back to the block recorded in `amounts.json`, checks that the source builds exactly those bytes and that metadata there, that the hash file is the hash of the bytes and that the Treasury Safe the bytes name has code, and runs the suite on the file's bytes. The RPC has to still serve that block, an archive node once it is old.

3. **The posted vote.** `forge script script/VerifyVote.s.sol` reads the script of the vote from the primary voting app with `getVote`, checks that it equals `script.hex` byte for byte, reads the vote's `StartVote` log to check that the Vault Safe created it with the metadata in `metadata.txt` (`getVote` returns neither the creator nor the metadata) and, while the vote is open, that the balances the script moves still cover the amounts in it. The vote id is the one in `proposal/vote-id.txt`, committed when the vote is posted, and it is the number in the dashboard's URL for the proposal, `#/governance/primary-<id>`. `--sig "check(uint256)" <id>` checks another vote.

So the vote on the chain is the committed bytes, the committed bytes are what the source builds at their block, and the source is what the tests pass. To read the posted bytes without Foundry, `cast call 0xDb6C812E439ce5c740570578681ea7aaDba5170b "getVote(uint256)(bool,bool,uint64,uint64,uint64,uint64,uint256,uint256,uint256,bytes)" <id>` prints them last, and `node scripts/decode-script.mjs <bytes>` turns them into the table above. The DAO dashboard shows the proposal only if `script-hash.txt` is on its allowlist, so the hash is one more thing to compare.

## Regenerating the voter set

`test/data/voters.json` lists real holders of voting power. The test takes them in order until yea exceeds 50% of all shares, and the set is generated with a 75% margin so it keeps working while stakes drift. When it no longer reaches 50%, or no listed voter clears the 0.1% proposal threshold, the test fails with a message saying so. Regenerate it with:

```bash
./scripts/pick-voters.sh
```

The script collects every past `CastVote` voter and the largest stakers from `Staked` events, adds their delegates, ranks them by `userVotingPower` at the latest block (or `FORK_BLOCK`), and keeps enough of them to hold 75% of all shares. It also picks stakers with locked rewards and no pending unstake for the unstake tests.
