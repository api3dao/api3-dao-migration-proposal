This vote winds down the Aragon-based API3 DAO and moves governance to Snapshot, where the Vault and Agent multisigs execute what passes. It fixes the API3 supply at 200,000,000: the pool stops minting rewards, the remainder is minted into the Vault Safe and the token's owner is set to the dead address, so no minter can ever be added again. The primary Agent's API3 moves to the Vault Safe and the secondary Agent's USDC, PNK, wPOKT and ETH move to the agent multisig. Both voting apps are then closed: nobody can create a vote, support and quorum sit at their maximum, and the permissions that could reopen them have no manager left.

Existing stakers keep every right they have today except voting: unstaking and withdrawing work unchanged, and locked rewards unlock on the same schedule.

The amounts are the balances at the block the bytes were built, right before posting. Every call is listed in Appendix A of the proposal, and the fork tests that replay these exact bytes are at
https://github.com/api3dao/api3-dao-migration-proposal
