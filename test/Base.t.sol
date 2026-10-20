// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../src/ShutdownScript.sol";

/// @notice Shared fixture of the fork tests. Forks mainnet, checks the permissions Appendix A relies on, takes the
/// vote script from one of three places and passes the vote with the voters in test/data/voters.json, real holders
/// of voting power:
///
/// - built from the source at the fork block, the default,
/// - read from the files CreateVote.s.sol wrote when GENERATED_DIR names their directory, forking at the block the
///   amounts were read at and checking every file against the source,
/// - read from the chain when VOTE_ID names a posted vote, checking its script against the files.
///
/// Execution is left to the tests: `executeNow` is the intended path, `executeAfterOneMoreEpoch` the fallback that
/// burns the overshoot. Fork only, nothing here touches mainnet.
abstract contract Base_Test is Test, ShutdownScript {
    uint256 constant NO_VOTE = type(uint256).max;

    address[] voters;
    address[] stakers;
    bytes script;
    string metadata;
    string generatedDir;
    bool voteOnChain;
    uint256 voteId;
    Amounts amounts;
    uint256 vaultApi3Before;
    uint256 agentSafeUsdcBefore;
    uint256 agentSafePnkBefore;
    uint256 agentSafeWpoktBefore;
    uint256 agentSafeEthBefore;

    function setUp() public virtual {
        string memory json = vm.readFile("test/data/voters.json");
        voters = vm.parseJsonAddressArray(json, ".voters");
        stakers = vm.parseJsonAddressArray(json, ".stakers");

        _loadVoteScript();
        _assertPermissionsAppendixAReliesOn();

        vaultApi3Before = API3.balanceOf(VAULT);
        agentSafeUsdcBefore = USDC.balanceOf(AGENT_SAFE);
        agentSafePnkBefore = PNK.balanceOf(AGENT_SAFE);
        agentSafeWpoktBefore = WPOKT.balanceOf(AGENT_SAFE);
        agentSafeEthBefore = AGENT_SAFE.balance;

        if (!voteOnChain) {
            vm.prank(_proposer());
            voteId = VOTING.newVote(script, metadata, true, false);
        }
        _pass(voteId);
    }

    // ------------------------------------------------------------ the script

    /// Where the bytes come from, see the contract comment. Amounts are fixed when the vote is posted, as the
    /// proposal says, so the file and chain modes take them from amounts.json rather than from the fork block.
    function _loadVoteScript() internal {
        uint256 envVote = vm.envOr("VOTE_ID", NO_VOTE);
        voteOnChain = envVote != NO_VOTE;
        generatedDir = vm.envOr("GENERATED_DIR", voteOnChain ? string("proposal/generated") : string(""));

        if (bytes(generatedDir).length == 0) {
            amounts = readAmounts();
            script = buildScript(amounts);
            metadata = buildMetadata("API3 DAO migration", "Fork rehearsal");
            console.log("script built from the source at block", block.number);
            return;
        }

        string memory json = vm.readFile(string.concat(generatedDir, "/amounts.json"));
        uint256 generatedBlock = vm.parseJsonUint(json, ".block");
        amounts = Amounts({
            mint: vm.parseJsonUint(json, ".mint"),
            agentApi3: vm.parseJsonUint(json, ".agentApi3"),
            secondaryUsdc: vm.parseJsonUint(json, ".secondaryUsdc"),
            secondaryPnk: vm.parseJsonUint(json, ".secondaryPnk"),
            secondaryWpokt: vm.parseJsonUint(json, ".secondaryWpokt"),
            secondaryEth: vm.parseJsonUint(json, ".secondaryEth")
        });
        script = vm.parseBytes(vm.readFile(string.concat(generatedDir, "/script.hex")));
        metadata = vm.readFile(string.concat(generatedDir, "/metadata.txt"));
        bytes32 hash = vm.parseBytes32(vm.readFile(string.concat(generatedDir, "/script-hash.txt")));
        assertEq(hash, keccak256(script), "script-hash.txt is the keccak256 of script.hex");
        console.log("script read from", generatedDir, "generated at block", generatedBlock);

        if (voteOnChain) {
            voteId = envVote;
            (bool open, bool executed, uint64 startDate, uint64 snapshotBlock,,,,,, bytes memory onChain) =
                VOTING.getVote(voteId);
            assertTrue(open, "the vote is open");
            assertFalse(executed, "the vote is not executed");
            assertEq(keccak256(onChain), keccak256(script), "the vote's script is the generated script");
            console.log("vote", voteId, "on the chain, snapshot block", snapshotBlock);
            console.log("vote start", startDate);
            return;
        }

        // The files are checked against the source where the source would produce them, at the block the amounts
        // were read at. That block has to be one the RPC still serves.
        vm.createSelectFork("mainnet", generatedBlock);
        assertEq(buildScript(readAmounts()), script, "script.hex is what the source builds at its block");
        string memory title = vm.readLine("proposal/title.txt");
        vm.closeFile("proposal/title.txt");
        assertEq(
            buildMetadata(title, vm.readFile("proposal/description.md")),
            metadata,
            "metadata.txt is the title and description in the dashboard's version 3 scheme"
        );
    }

    /// The permissions Appendix A relies on, as they stand on chain.
    function _assertPermissionsAppendixAReliesOn() internal view {
        assertTrue(API3.getMinterStatus(address(POOL)), "pool starts as a minter");
        assertEq(API3.owner(), address(AGENT), "primary Agent owns the token");
        assertTrue(ACL.hasPermission(ANY_ENTITY, address(VOTING), CREATE_VOTES_ROLE), "anyone can create primary votes");
        assertTrue(
            ACL.hasPermission(ANY_ENTITY, address(VOTING_SECONDARY), CREATE_VOTES_ROLE),
            "anyone can create secondary votes"
        );
        assertTrue(
            ACL.hasPermission(address(AGENT), address(VOTING), MODIFY_SUPPORT_ROLE), "agent can change primary support"
        );
        assertTrue(
            ACL.hasPermission(address(AGENT), address(VOTING_SECONDARY), MODIFY_QUORUM_ROLE),
            "agent can change secondary quorum"
        );
        assertEq(
            ACL.getPermissionManager(address(AGENT_SECONDARY), TRANSFER_ROLE),
            address(VOTING),
            "primary voting manages secondary transfers"
        );
        assertTrue(
            ACL.hasPermission(address(VOTING), address(ACL), CREATE_PERMISSIONS_ROLE),
            "primary voting can create permissions"
        );
        assertEq(
            ACL.getPermissionManager(address(ACL), CREATE_PERMISSIONS_ROLE),
            address(VOTING),
            "primary voting manages permission creation"
        );
        assertTrue(ACL.hasPermission(address(VOTING), address(KERNEL), APP_MANAGER_ROLE), "primary voting can set apps");
        assertEq(
            ACL.getPermissionManager(address(KERNEL), APP_MANAGER_ROLE),
            address(VOTING),
            "primary voting manages app management"
        );
    }

    // ------------------------------------------------------------ passing and executing

    /// Votes yea with the listed voters, in order, until yea exceeds half of all voting power.
    function _pass(uint256 id) internal {
        (,,, uint64 snapshotBlock,,, uint256 yea,, uint256 votingPower,) = VOTING.getVote(id);
        for (uint256 i; i < voters.length && yea * PCT_BASE / votingPower <= PCT_BASE / 2; i++) {
            if (POOL.userVotingPowerAt(voters[i], snapshotBlock) == 0) continue;
            vm.prank(voters[i]);
            VOTING.vote(id, true, false);
            (,,,,,, yea,,,) = VOTING.getVote(id);
        }
        assertGt(yea * PCT_BASE / votingPower, PCT_BASE / 2, "yea exceeds half of all voting power");
        assertTrue(VOTING.canExecute(id), "a decided primary can execute before the vote ends");
        console.log("vote", id, "yea % of voting power", yea * 100 / votingPower);
    }

    /// The intended path: executed before the pool mints another epoch.
    function executeNow() internal {
        VOTING.executeVote(voteId);
        _nextBlock();
    }

    /// The fallback path: the pool mints one more epoch first, the supply overshoots by that reward and the Vault
    /// Safe burns the surplus afterwards.
    function executeAfterOneMoreEpoch() internal returns (uint256 overshoot, uint256 reward) {
        _nextEpoch();
        uint256 supply = API3.totalSupply();
        POOL.mintReward();
        reward = API3.totalSupply() - supply;
        VOTING.executeVote(voteId);
        overshoot = API3.totalSupply() - TARGET_SUPPLY;
        vm.startPrank(VAULT);
        API3.updateBurnerStatus(true);
        API3.burn(overshoot);
        vm.stopPrank();
        _nextBlock();
    }

    /// What every execution path has to leave behind.
    function _assertOutcome() internal view {
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "total supply is exactly 200M");
        assertEq(API3.owner(), DEAD, "token owner is the dead address, minter set is frozen");
        assertFalse(API3.getMinterStatus(address(POOL)), "pool cannot mint");
        assertFalse(API3.getMinterStatus(address(AGENT)), "agent cannot mint");
        assertEq(API3.balanceOf(address(AGENT)), 0, "primary agent emptied");
        assertEq(USDC.balanceOf(address(AGENT_SECONDARY)), 0, "secondary agent USDC emptied");
        assertEq(PNK.balanceOf(address(AGENT_SECONDARY)), 0, "secondary agent PNK emptied");
        assertEq(WPOKT.balanceOf(address(AGENT_SECONDARY)), 0, "secondary agent wPOKT emptied");
        assertEq(address(AGENT_SECONDARY).balance, 0, "secondary agent ETH emptied");
        assertEq(
            USDC.balanceOf(AGENT_SAFE), agentSafeUsdcBefore + amounts.secondaryUsdc, "agent multisig received USDC"
        );
        assertEq(PNK.balanceOf(AGENT_SAFE), agentSafePnkBefore + amounts.secondaryPnk, "agent multisig received PNK");
        assertEq(
            WPOKT.balanceOf(AGENT_SAFE), agentSafeWpoktBefore + amounts.secondaryWpokt, "agent multisig received wPOKT"
        );
        assertEq(AGENT_SAFE.balance, agentSafeEthBefore + amounts.secondaryEth, "agent multisig received ETH");
    }

    // ------------------------------------------------------------ helpers

    /// The first listed voter that still clears the pool's proposal threshold (0.1% of all shares).
    function _proposer() internal view returns (address) {
        uint256 needed = POOL.totalShares() * POOL.proposalVotingPowerThreshold() / PCT_BASE;
        for (uint256 i; i < voters.length; i++) {
            if (POOL.userVotingPower(voters[i]) >= needed) return voters[i];
        }
        revert("no voter in test/data/voters.json can propose, regenerate it");
    }

    /// Everything after execution happens in later blocks, as it would on mainnet.
    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _nextEpoch() internal {
        uint256 target = ((block.timestamp / EPOCH) + 1) * EPOCH + 1;
        vm.roll(block.number + (target - block.timestamp) / 12);
        vm.warp(target);
    }

    function _passDays(uint256 numDays) internal {
        vm.warp(block.timestamp + numDays * 1 days + 1);
        vm.roll(block.number + numDays * 1 days / 12);
    }

    function _stakerWithoutPendingUnstake() internal view returns (address) {
        for (uint256 i; i < stakers.length; i++) {
            (,,,, uint256 scheduledFor,,) = POOL.getUser(stakers[i]);
            if (scheduledFor == 0 && POOL.userStake(stakers[i]) > 0 && POOL.userLocked(stakers[i]) > 0) {
                return stakers[i];
            }
        }
        revert("no suitable staker in test/data/voters.json");
    }

    /// Withdraws the largest amount the pool allows, bounded by the unstaked balance and by the locked rewards and
    /// vesting that have to stay covered by the user's total funds. One wei more is refused.
    function _withdrawUnlocked(address user) internal returns (uint256 amount) {
        (uint256 unstaked, uint256 vesting,,,,,) = POOL.getUser(user);
        uint256 totalFunds = unstaked + POOL.userStake(user);
        uint256 free = totalFunds - POOL.userLocked(user) - vesting;
        amount = free < unstaked ? free : unstaked;
        vm.prank(user);
        vm.expectRevert(bytes("Pool: Not enough unlocked funds"));
        POOL.withdrawRegular(amount + 1);
        vm.prank(user);
        POOL.withdrawRegular(amount);
    }
}

/// The state after the intended execution, the fixture of every tree that looks at the DAO and the pool afterwards.
abstract contract Executed_Test is Base_Test {
    function setUp() public virtual override {
        super.setUp();
        executeNow();
    }
}
