// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../src/MigrationScript.sol";

/// @notice Shared fixture of the fork tests. Forks mainnet, checks the permissions the script relies on, builds the
/// vote script from the source at the fork block, the metadata from the proposal files, and passes the vote with the
/// voters in test/data/voters.json, real holders of voting power. The posted vote is checked against the same source
/// by script/VerifyVote.s.sol.
///
/// Execution is left to the tests: `executeNow` is the intended path, `executeAfterOneMoreEpoch` the fallback that
/// burns the overshoot. Fork only, nothing here touches mainnet.
abstract contract Base_Test is Test, MigrationScript {
    address[] voters;
    address[] stakers;
    bytes script;
    string metadata;
    uint256 voteId;
    Amounts amounts;
    uint256 treasuryApi3Before;
    uint256 agentSafeUsdcBefore;
    uint256 agentSafePnkBefore;
    uint256 agentSafeWpoktBefore;
    uint256 agentSafeEthBefore;

    function setUp() public virtual {
        string memory json = vm.readFile("test/data/voters.json");
        voters = vm.parseJsonAddressArray(json, ".voters");
        stakers = vm.parseJsonAddressArray(json, ".stakers");

        amounts = readAmounts();
        script = buildScript(amounts);
        metadata = buildMetadata(vm.readLine("proposal/title.txt"), vm.trim(vm.readFile("proposal/description.md")));
        _assertPermissionsTheScriptReliesOn();

        treasuryApi3Before = API3.balanceOf(TREASURY_SAFE);
        agentSafeUsdcBefore = USDC.balanceOf(AGENT_SAFE);
        agentSafePnkBefore = PNK.balanceOf(AGENT_SAFE);
        agentSafeWpoktBefore = WPOKT.balanceOf(AGENT_SAFE);
        agentSafeEthBefore = AGENT_SAFE.balance;

        vm.prank(_proposer());
        voteId = VOTING.newVote(script, metadata, true, false);
        _pass(voteId);
    }

    /// The permissions the script relies on, as they stand on chain.
    function _assertPermissionsTheScriptReliesOn() internal view {
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

    /// The fallback path: the pool mints one more epoch first, the supply overshoots by that reward and the
    /// Treasury Safe, where the mint landed, burns the surplus afterwards. The burner opt-in is a one-time call the
    /// Treasury Safe makes before the vote opens, here it is made when missing.
    function executeAfterOneMoreEpoch() internal returns (uint256 overshoot, uint256 reward) {
        _nextEpoch();
        uint256 supply = API3.totalSupply();
        POOL.mintReward();
        reward = API3.totalSupply() - supply;
        VOTING.executeVote(voteId);
        overshoot = API3.totalSupply() - TARGET_SUPPLY;
        vm.startPrank(TREASURY_SAFE);
        if (!API3.getBurnerStatus(TREASURY_SAFE)) API3.updateBurnerStatus(true);
        API3.burn(overshoot);
        vm.stopPrank();
        _nextBlock();
    }

    /// What every execution path has to leave behind.
    function _assertOutcome() internal view {
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "total supply is exactly 200M");
        assertEq(API3.owner(), DEAD, "token owner is the dead address, minter set is final");
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
