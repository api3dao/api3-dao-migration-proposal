# API3 DAO migration proposal

Everything behind the primary vote that winds down the Aragon-based API3 DAO and moves governance to Snapshot: the vote script, Foundry fork tests that run it through the real Aragon apps and check that the staking pool keeps working afterwards, a decoder that prints the script as a table, and a preview of the proposal in the DAO dashboard. Everything runs against a fork, nothing here broadcasts a transaction to mainnet.

## Running

Needs [Foundry](https://getfoundry.sh) and a mainnet RPC in `ETH_RPC_URL`, an archive one if you pin a historical block. [bulloak](https://github.com/alexfertel/bulloak) checks the test trees, see below. The decoder and the dashboard preview need Node and pnpm, nothing else does.

```bash
./setup.sh
export ETH_RPC_URL=<mainnet RPC>
forge test -vv
bulloak check test/vote/*.tree test/dao/*.tree test/pool/*.tree
```

## What the vote does

One primary vote, passed by real voting power (`test/data/voters.json`). [src/ShutdownScript.sol](src/ShutdownScript.sol) builds the script, the same bytes for the tests and for the vote that gets posted, following Appendix A of the proposal row by row. Calls to the ACL and the primary Agent come from the primary voting app, everything else goes through the primary Agent's `execute`. A NOTE marks where the script differs from the appendix:

1. ACL: grant the primary Agent `TRANSFER_ROLE` on the secondary Agent. NOTE: the script also grants `EXECUTE_ROLE`, which the appendix does not list. Aragon's Vault sends ETH with `send`, and the 2300 gas stipend is not enough for a Safe to receive it (`VAULT_SEND_REVERTED` on the fork), so the ETH in row 2 goes through `execute`. The primary voting app manages that role too, so no other vote is needed.
2. Secondary Agent: transfer its USDC, PNK and wPOKT to the agent multisig, and its ETH through `execute`. NOTE: the amounts are read from the chain when the script is built, the appendix quotes a snapshot refreshed at posting.
3. Primary Agent: transfer its API3 to the Treasury Safe. NOTE: the appendix names the Vault Safe, see below.
4. Token: revoke the pool's minter status. Rewards stop.
5. Token: grant the primary Agent minter status.
6. Token: mint the remainder to 200,000,000 API3 into the Treasury Safe. NOTE: the appendix names the Vault Safe.
7. Token: revoke the primary Agent's minter status.
8. Token: transfer ownership to `0x000000000000000000000000000000000000dEaD`. `Api3Token.renounceOwnership()` reverts by design, so this is the only way to freeze the minter set.
9. ACL: revoke the right of any address to create votes on both voting apps.
10. ACL: remove the manager of that right on both apps, so nobody can grant it again.
11. Both voting apps: raise support and quorum to the contract maximum, support first because the app rejects a quorum above the support, then remove the managers of both roles on both apps.
12. ACL: revoke the primary voting app's `CREATE_PERMISSIONS_ROLE` on the ACL and `APP_MANAGER_ROLE` on the Kernel, and remove both managers. NOTE: not in the appendix. These are the DAO's root permissions, both held and managed by the primary voting app. Removing a permission's manager, as rows 10 and 11 do, is what lets a holder of `CREATE_PERMISSIONS_ROLE` create that permission again, and `APP_MANAGER_ROLE` swaps the code behind any app. Rows 9 and 10 already put both out of reach, since only a primary vote could use them. This row makes that hold even for a vote created through a route not seen, or one still open at execution.

The Treasury Safe is a new Safe for the API3 the vote moves. It only holds, with the same signers as the Vault and Agent Safes, which execute what passes, and it never votes on Snapshot. The Vault Safe, which many pool delegations name, votes there with that delegated stake and its own holdings, so the treasury's weight stays out of its hands. It is `0xb7fa2Cb302C5dC127e61F27b92beC411cbf0AE4A`, 3 of 5 with the same signers, and its Snapshot voting power is delegated to the dead address. `CreateVote.s.sol` and the file and posted-vote test modes check that the address has code.

The mint amount is fixed when the script is built. A primary vote can execute the moment yea exceeds 50% of all voting power, and the intended path executes it there, before the next weekly reward mint, so the supply lands on exactly 200,000,000 with nothing to burn. The fallback path is rehearsed too: one more epoch is minted before execution, about 0.95M API3 at the current APR, and the Treasury Safe, which received the mint, burns the overshoot with `burn(excess)`, having registered as a burner with `updateBurnerStatus(true)` before the vote opened.

## What the tests assert

The tests follow the branching tree technique: each `.tree` file spells out what is checked, as conditions and the outcomes under them, and the `.t.sol` next to it has one test per branch, named after it. [test/Base.t.sol](test/Base.t.sol) is the shared fixture, it forks mainnet, takes the script (see below), passes the vote with the voters in `test/data/voters.json` and leaves execution to the tests.

| tree                                       | what it checks                                                                                                                                      |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [test/vote/script.tree](test/vote/script.tree)     | the bytes: the CallsScript shape and its 28 calls, every call on the ACL or the primary Agent, version 3 metadata, and the generated files against the source and the chain |
| [test/vote/execute.tree](test/vote/execute.tree)   | the outcome on both paths: supply exactly 200,000,000, the token frozen, both agents emptied into the multisigs, the Treasury Safe credited, the overshoot burned on the late path, a burn before execution left as it is |
| [test/dao/closed.tree](test/dao/closed.tree)       | the old DAO after the vote: no vote can be created, support and quorum at the maximum, the root permissions gone, even for the primary voting app itself |
| [test/pool/rewards.tree](test/pool/rewards.tree)   | `mintReward()` mints nothing after the shutdown, the total stake holds and the epoch cursor keeps advancing                                           |
| [test/pool/staking.tree](test/pool/staking.tree)   | stakers keep every right but voting: a full exit, locked rewards unlocking over 52 epochs, a new staker's round trip, a partial exit and re-entry over a year |

`bulloak check` confirms that every tree and its test file still match.

## The bytes

[script/CreateVote.s.sol](script/CreateVote.s.sol) builds the script and the metadata string from the chain state at the current block. The title and description of the vote are [proposal/title.txt](proposal/title.txt) and [proposal/description.md](proposal/description.md), joined into the DAO dashboard's metadata scheme version 3 (`3`, title, description, separated by `0x1f`), the version the dashboard decodes from the script alone.

```bash
forge script script/CreateVote.s.sol --rpc-url mainnet
node scripts/decode-script.mjs proposal/generated/script.hex
```

The first command writes `proposal/generated/`: `script.hex`, `script-hash.txt` (its keccak256, which the dashboard has to know to show the proposal), `metadata.txt`, `amounts.json` with the block the amounts were read at, and `vote-id.txt`, which is only meaningful after a broadcast (see below). Without `--broadcast` the `newVote` call is simulated and nothing is sent. The second prints the calls as a table, one row per Appendix A call, with the roles, addresses and amounts named, and prints anything it does not recognise raw. It is a reading aid: the byte for byte comparisons are the tests below.

To rebuild the published bytes rather than fresh ones, pin the block from `amounts.json`: `forge script script/CreateVote.s.sol --rpc-url mainnet --fork-block-number <block>` writes the same files again, against an archive node once the block is old. Every amount has to be positive when the bytes are built, Aragon's Vault refuses a zero transfer and one reverting call reverts the whole script, so a row with nothing left to move has to be dropped from the script instead.

## Verify it yourself

Everything below is read-only and needs no account, only an RPC. The same suite runs in three modes, chosen by two environment variables, and every assertion runs in each of them.

1. **The source.** `forge test` builds the script from `src/ShutdownScript.sol` at the fork block and runs the suite on it. This is what the bytes are supposed to be.

2. **The published files.** `GENERATED_DIR=proposal/generated forge test` reads `script.hex`, `metadata.txt`, `amounts.json` and `script-hash.txt` from that directory instead, forks mainnet at the block recorded in `amounts.json`, checks that the source builds exactly those bytes and that metadata there, that the hash file is the hash of the bytes, that the Treasury Safe the bytes name has code, and runs the suite on the file's bytes. The directory has to be under `proposal/`, the only place the tests may read, and the RPC has to still serve that block, an archive node once it is old.

3. **The posted vote.** `VOTE_ID=<id> forge test` reads the script of that vote from the primary voting app with `getVote`, checks that the vote is open and not executed and that its script equals `proposal/generated/script.hex` byte for byte, reads the vote's `StartVote` log to check that the Vault Safe created it with the metadata in `metadata.txt` (`getVote` returns neither the creator nor the metadata), checks that the balances the script moves still equal the amounts in it and that the Treasury Safe has code, then passes that very vote with the listed voters and runs the suite on it. Run it in the epoch the vote was posted in, so the amounts in the vote are still the balances, otherwise the fallback path in `test/vote/execute.tree` is the one that applies. This mode checks the chain against the files, mode 2 checks the files against the source, so a verifier runs both. Run it on the tree tests, `--match-path 'test/*/*.t.sol'`: the older `test/ShutdownProposal.t.sol` always posts a vote of its own from the first listed voter, the Vault Safe once it has posted the real one, and fails on the pool's one week proposal cooldown.

To read the posted bytes without Foundry's test runner, `cast call 0xDb6C812E439ce5c740570578681ea7aaDba5170b "getVote(uint256)(bool,bool,uint64,uint64,uint64,uint64,uint256,uint256,uint256,bytes)" <id> --rpc-url $ETH_RPC_URL` prints them last, and `node scripts/decode-script.mjs <bytes>` turns them into the Appendix A table. The DAO dashboard shows the proposal only if `script-hash.txt` is on its allowlist, so the hash is one more thing to compare.

## Previewing the vote in the DAO dashboard

```bash
./dashboard-preview.sh
```

Forks mainnet with anvil as chain id 31337, has the impersonated Vault Safe post the vote through `CreateVote.s.sol`, writes the dashboard's `.env` so that its hardhat network entry points at the fork and the script's hash is known to it, and starts the dashboard. The script prints the proposal's URL. The dashboard checkout is `./api3-dao-dashboard`, which `setup.sh` clones, `DASHBOARD_DIR` overrides it. Rendering a proposal with several calls needs the dashboard's `multi-call-proposals` branch until it is upstream.

Open the URL in a browser profile without a wallet extension and the dashboard connects by itself as the first anvil account. With MetaMask, add a network by hand and connect through it:

- RPC URL `http://localhost:57751`
- chain id `31337`
- currency symbol `ETH`

The header reads "Connected to hardhat" once that network is selected, the dashboard reaches the fork through its hardhat network entry, whose addresses are the mainnet ones. `ANVIL_PORT` and `DASHBOARD_PORT` change the ports. The script runs until it is stopped and takes anvil and the dashboard down with it, running it again gives a fresh fork and a new vote id.

For a last check against the production build, run anvil with `--chain-id 1` instead, point the wallet's mainnet RPC at it, build the dashboard with `VITE_MAINNET_PROVIDER_URL` set to the fork and serve it with `pnpm preview`. That exercises the `mainnet` code path with the production addresses.

## Regenerating the voter set

`test/data/voters.json` lists real holders of voting power. The test takes them in order until yea exceeds 50% of all shares, and the set is generated with a 75% margin so it keeps working while stakes drift. When it no longer reaches 50%, or no listed voter clears the 0.1% proposal threshold, the test fails with a message saying so. Regenerate it with:

```bash
./scripts/pick-voters.sh
```

The script collects every past `CastVote` voter and the largest stakers from `Staked` events, adds their delegates, ranks them by `userVotingPower` at the latest block (or `FORK_BLOCK`), and keeps enough of them to hold 75% of all shares. It also picks stakers with locked rewards and no pending unstake for the unstake tests.
