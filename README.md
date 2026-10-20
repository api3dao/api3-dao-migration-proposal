# API3 DAO migration proposal

Everything behind the primary vote that winds down the Aragon-based API3 DAO and moves governance to Snapshot: the vote script, Foundry fork tests that run it through the real Aragon apps and check that the staking pool keeps working afterwards, a decoder that prints the script as a table, and a preview of the proposal in the DAO dashboard. Everything runs against a fork, nothing here broadcasts a transaction to mainnet.

## Running

Needs [Foundry](https://getfoundry.sh) and a mainnet RPC in `ETH_RPC_URL`, an archive one if you pin a historical block.

```bash
./setup.sh
export ETH_RPC_URL=<mainnet RPC>
forge test -vv
```

## What the vote does

One primary vote, passed by real voting power (`test/data/voters.json`). [src/ShutdownScript.sol](src/ShutdownScript.sol) builds the script, the same bytes for the tests and for the vote that gets posted, following Appendix A of the proposal row by row. Calls to the ACL and the primary Agent come from the primary voting app, everything else goes through the primary Agent's `execute`. A NOTE marks where the script differs from the appendix:

1. ACL: grant the primary Agent `TRANSFER_ROLE` on the secondary Agent. NOTE: the script also grants `EXECUTE_ROLE`, which the appendix does not list. Aragon's Vault sends ETH with `send`, and the 2300 gas stipend is not enough for a Safe to receive it (`VAULT_SEND_REVERTED` on the fork), so the ETH in row 2 goes through `execute`. The primary voting app manages that role too, so no other vote is needed.
2. Secondary Agent: transfer its USDC, PNK and wPOKT to the agent multisig, and its ETH through `execute`. NOTE: the amounts are read from the chain when the script is built, the appendix quotes a snapshot refreshed at posting.
3. Primary Agent: transfer its API3 to the Vault Safe.
4. Token: revoke the pool's minter status. Rewards stop.
5. Token: grant the primary Agent minter status.
6. Token: mint the remainder to 200,000,000 API3 into the Vault Safe.
7. Token: revoke the primary Agent's minter status.
8. Token: transfer ownership to `0x000000000000000000000000000000000000dEaD`. `Api3Token.renounceOwnership()` reverts by design, so this is the only way to freeze the minter set.
9. ACL: revoke the right of any address to create votes on both voting apps.
10. ACL: remove the manager of that right on both apps, so nobody can grant it again.
11. Both voting apps: raise support and quorum to the contract maximum, support first because the app rejects a quorum above the support, then remove the managers of both roles on both apps.
12. ACL: revoke the primary voting app's `CREATE_PERMISSIONS_ROLE` on the ACL and `APP_MANAGER_ROLE` on the Kernel, and remove both managers. NOTE: not in the appendix. These are the DAO's root permissions, both held and managed by the primary voting app. Removing a permission's manager, as rows 10 and 11 do, is what lets a holder of `CREATE_PERMISSIONS_ROLE` create that permission again, and `APP_MANAGER_ROLE` swaps the code behind any app. Rows 9 and 10 already put both out of reach, since only a primary vote could use them. This row makes that hold even for a vote created through a route not seen, or one still open at execution.

The mint amount is fixed when the script is built. A primary vote can execute the moment yea exceeds 50% of all voting power, and `ShutdownProposalTest` executes it there, before the next weekly reward mint, so the supply lands on exactly 200,000,000 with nothing to burn. `ShutdownProposalLateExecutionTest` rehearses the fallback: one more epoch is minted before execution, about 0.95M API3 at the current 75% APR, and the Vault Safe burns the overshoot with `updateBurnerStatus(true)` and `burn(excess)`.

## What the tests assert

| test                                        | asserts                                                                                                                                                       |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ShutdownProposalTest.test_01`              | total supply is exactly 200,000,000 API3, the token owner is the dead address, nobody can mint, both agents are emptied into the multisigs                     |
| `ShutdownProposalTest.test_02`              | `mintReward()` skips epochs without reverting and the epoch cursor keeps advancing                                                                            |
| `ShutdownProposalTest.test_03`              | no vote can be created on either app, and both apps sit at the maximum support and quorum with no manager left to lower them                                  |
| `ShutdownProposalTest.test_04`              | an existing staker schedules a full unstake, unstakes after 7 days, withdraws everything that is not locked, and cannot withdraw one wei more                  |
| `ShutdownProposalTest.test_05`              | that staker's locked rewards shrink after 26 epochs and are zero after 52, then the whole balance is withdrawable                                              |
| `ShutdownProposalTest.test_06`              | a new address deposits and stakes, then exits with its full deposit and nothing locked                                                                        |
| `ShutdownProposalTest.test_07`              | the root permissions are gone: even the primary voting app can no longer create a permission or swap an app's code                                            |
| `ShutdownProposalTest.test_08`              | after two idle epochs an existing staker unstakes half, withdraws, re-deposits and stakes it, schedules a full unstake, and a year later withdraws everything but their vesting |
| `ShutdownProposalLateExecutionTest.test_01` | with one more reward epoch minted before execution, the burn lands the supply on exactly 200,000,000 and the vault pays it                                     |

## The bytes

[script/CreateVote.s.sol](script/CreateVote.s.sol) builds the script and the metadata string from the chain state at the current block. The title and description of the vote are [proposal/title.txt](proposal/title.txt) and [proposal/description.md](proposal/description.md), joined into the DAO dashboard's metadata scheme version 3 (`3`, title, description, separated by `0x1f`), the version the dashboard decodes from the script alone.

```bash
forge script script/CreateVote.s.sol --rpc-url mainnet
./scripts/decode-script.py proposal/generated/script.hex
```

The first command writes `proposal/generated/`: `script.hex`, `script-hash.txt` (its keccak256, which the dashboard has to know to show the proposal), `metadata.txt`, `amounts.json` with the block the amounts were read at, and `vote-id.txt`, which is only meaningful after a broadcast (see below). Without `--broadcast` the `newVote` call is simulated and nothing is sent. The second prints the calls as a table, one row per Appendix A call, with the roles, addresses and amounts named, and prints anything it does not recognise raw.

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
