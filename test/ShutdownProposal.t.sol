// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/ShutdownScript.sol";

/// @notice Fork rehearsal of the primary proposal that winds down the legacy DAO. The vote script
/// is the one `ShutdownScript` builds, the same bytes that get posted.
///
/// The vote is passed by the addresses in test/data/voters.json, real holders of voting power.
/// `_execute` is the only thing the two concrete contracts differ in: the intended path executes
/// the moment the vote is decided, before the next weekly reward mint, and the fallback path
/// executes after one more mint and burns the overshoot.
///
/// Fork only. Nothing here touches mainnet.
abstract contract ShutdownProposalBase is Test, ShutdownScript {
    address[] voters;
    address[] stakers;
    uint256 voteId;
    uint256 mintAmount;
    uint256 agentApi3;
    uint256 secondaryUsdc;
    uint256 secondaryPnk;
    uint256 secondaryWpokt;
    uint256 secondaryEth;
    uint256 treasuryApi3Before;
    uint256 agentSafeUsdcBefore;
    uint256 agentSafePnkBefore;
    uint256 agentSafeWpoktBefore;
    uint256 agentSafeEthBefore;

    function setUp() public {
        string memory json = vm.readFile("test/data/voters.json");
        voters = vm.parseJsonAddressArray(json, ".voters");
        stakers = vm.parseJsonAddressArray(json, ".stakers");

        // The permissions Appendix A relies on, as they stand on chain.
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

        // Amounts are fixed when the vote is posted, as the proposal says.
        Amounts memory amounts = readAmounts();
        mintAmount = amounts.mint;
        agentApi3 = amounts.agentApi3;
        secondaryUsdc = amounts.secondaryUsdc;
        secondaryPnk = amounts.secondaryPnk;
        secondaryWpokt = amounts.secondaryWpokt;
        secondaryEth = amounts.secondaryEth;
        treasuryApi3Before = API3.balanceOf(TREASURY_SAFE);
        agentSafeUsdcBefore = USDC.balanceOf(AGENT_SAFE);
        agentSafePnkBefore = PNK.balanceOf(AGENT_SAFE);
        agentSafeWpoktBefore = WPOKT.balanceOf(AGENT_SAFE);
        agentSafeEthBefore = AGENT_SAFE.balance;

        voteId = _createAndPass(buildScript(amounts), buildMetadata("API3 DAO migration", "Fork rehearsal"));
        _execute();
        // Everything after this happens in later blocks, as it would on mainnet.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _execute() internal virtual;

    // ---------------------------------------------------------------- helpers

    function _createAndPass(bytes memory script, string memory metadata) internal returns (uint256 id) {
        vm.prank(_proposer());
        id = VOTING.newVote(script, metadata, true, false);
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

    /// The first listed voter that still clears the pool's proposal threshold (0.1% of all shares).
    function _proposer() internal view returns (address) {
        uint256 needed = POOL.totalShares() * POOL.proposalVotingPowerThreshold() / PCT_BASE;
        for (uint256 i; i < voters.length; i++) {
            if (POOL.userVotingPower(voters[i]) >= needed) return voters[i];
        }
        revert("no voter in test/data/voters.json can propose, regenerate it");
    }

    function _nextEpoch() internal {
        uint256 target = ((block.timestamp / EPOCH) + 1) * EPOCH + 1;
        vm.roll(block.number + (target - block.timestamp) / 12);
        vm.warp(target);
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
        assertEq(USDC.balanceOf(AGENT_SAFE), agentSafeUsdcBefore + secondaryUsdc, "agent multisig received USDC");
        assertEq(PNK.balanceOf(AGENT_SAFE), agentSafePnkBefore + secondaryPnk, "agent multisig received PNK");
        assertEq(WPOKT.balanceOf(AGENT_SAFE), agentSafeWpoktBefore + secondaryWpokt, "agent multisig received wPOKT");
        assertEq(AGENT_SAFE.balance, agentSafeEthBefore + secondaryEth, "agent multisig received ETH");
    }
}

/// The intended path: the vote is decided and executed before the pool mints another epoch, so
/// the mint fixed at posting lands the supply on exactly 200M with nothing to burn.
contract ShutdownProposalTest is ShutdownProposalBase {
    function _execute() internal override {
        VOTING.executeVote(voteId);
    }

    // ---------------------------------------------------------------- outcome of the vote

    function test_01_supply_is_exactly_200M_treasury_moved_and_minting_is_gone() public view {
        _assertOutcome();
        assertEq(
            API3.balanceOf(TREASURY_SAFE),
            treasuryApi3Before + mintAmount + agentApi3,
            "the Treasury Safe received the mint and the agent treasury"
        );
        console.log("minted by the vote (API3)    ", mintAmount / 1e18);
        console.log("agent treasury moved (API3)  ", agentApi3 / 1e18);
        console.log("secondary agent USDC moved   ", secondaryUsdc / 1e6);
    }

    function test_02_pool_skips_reward_epochs_without_reverting() public {
        uint256 supply = API3.totalSupply();
        uint256 stake = POOL.totalStake();
        for (uint256 i; i < 3; i++) {
            _nextEpoch();
            POOL.mintReward();
        }
        assertEq(API3.totalSupply(), supply, "nothing minted");
        assertEq(POOL.totalStake(), stake, "total stake unchanged");
        assertEq(POOL.epochIndexOfLastReward(), block.timestamp / EPOCH, "cursor keeps advancing");
    }

    function test_03_old_dao_is_closed() public {
        // No vote can be created on either app.
        vm.prank(_proposer());
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        VOTING.newVote(hex"00000001", "after the wind-down", true, false);
        vm.prank(_proposer());
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        VOTING_SECONDARY.newVote(hex"00000001", "after the wind-down", true, false);
        assertEq(
            ACL.getPermissionManager(address(VOTING), CREATE_VOTES_ROLE),
            address(0),
            "primary vote creation has no manager"
        );
        assertEq(
            ACL.getPermissionManager(address(VOTING_SECONDARY), CREATE_VOTES_ROLE),
            address(0),
            "secondary vote creation has no manager"
        );

        // Second lock: both apps need every last vote to pass anything.
        assertEq(VOTING.supportRequiredPct(), MAX_PCT);
        assertEq(VOTING.minAcceptQuorumPct(), MAX_PCT);
        assertEq(VOTING_SECONDARY.supportRequiredPct(), MAX_PCT);
        assertEq(VOTING_SECONDARY.minAcceptQuorumPct(), MAX_PCT);
        assertEq(ACL.getPermissionManager(address(VOTING), MODIFY_SUPPORT_ROLE), address(0));
        assertEq(ACL.getPermissionManager(address(VOTING_SECONDARY), MODIFY_QUORUM_ROLE), address(0));
    }

    // ---------------------------------------------------------------- existing stakers

    function test_04_existing_staker_unstakes_and_withdraws_unlocked_part() public {
        address staker = _stakerWithoutPendingUnstake();
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 lockedBefore = POOL.userLocked(staker);
        (uint256 unstakedBefore, uint256 vesting,,,,,) = POOL.getUser(staker);
        assertGt(stakeBefore, 0, "staker has stake");
        assertGt(lockedBefore, 0, "staker has locked rewards");

        vm.prank(staker);
        POOL.scheduleUnstake(stakeBefore);
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.roll(block.number + 1 weeks / 12);
        uint256 unstaked = POOL.unstake(staker);
        assertApproxEqRel(unstaked, stakeBefore, 1e12, "unstake returns the staked amount");
        assertLt(POOL.userStake(staker), 1e6, "only rounding dust of stake is left");

        uint256 locked = POOL.userLocked(staker);
        // Total funds include the few wei of stake that rounding leaves behind.
        uint256 totalFunds = unstakedBefore + unstaked + POOL.userStake(staker);
        uint256 withdrawable = totalFunds - locked - vesting;
        uint256 balance = API3.balanceOf(staker);

        vm.prank(staker);
        vm.expectRevert(bytes("Pool: Not enough unlocked funds"));
        POOL.withdrawRegular(withdrawable + 1);

        vm.prank(staker);
        POOL.withdrawRegular(withdrawable);
        assertEq(API3.balanceOf(staker), balance + withdrawable, "unlocked part withdrawn");
        console.log("staker                 ", staker);
        console.log("stake (API3)           ", stakeBefore / 1e18);
        console.log("locked (API3)          ", locked / 1e18);
        console.log("withdrawn now (API3)   ", withdrawable / 1e18);
    }

    function test_05_locked_rewards_unlock_as_epochs_pass_then_everything_is_withdrawable() public {
        address staker = _stakerWithoutPendingUnstake();
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 lockedStart = POOL.userLocked(staker);
        (, uint256 vesting,,,,,) = POOL.getUser(staker);
        assertGt(lockedStart, 0);

        vm.prank(staker);
        POOL.scheduleUnstake(stakeBefore);
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.roll(block.number + 1 weeks / 12);
        POOL.unstake(staker);

        // Half the vesting window: strictly less locked than at the start.
        for (uint256 i; i < 26; i++) {
            _nextEpoch();
        }
        uint256 lockedHalf = POOL.userLocked(staker);
        assertLt(lockedHalf, lockedStart, "locked amount decreases as reward epochs age out");

        // Full vesting window since the last reward epoch: nothing locked any more.
        for (uint256 i; i < 27; i++) {
            _nextEpoch();
        }
        assertEq(POOL.userLocked(staker), 0, "all rewards unlocked");

        (uint256 unstaked,,,,,,) = POOL.getUser(staker);
        uint256 balance = API3.balanceOf(staker);
        vm.prank(staker);
        POOL.withdrawRegular(unstaked - vesting);
        assertEq(API3.balanceOf(staker), balance + unstaked - vesting, "full balance withdrawn");
        (uint256 unstakedAfter,,,,,,) = POOL.getUser(staker);
        assertEq(unstakedAfter, vesting, "only timelocked vesting can remain");
        console.log("locked at start (API3)      ", lockedStart / 1e18);
        console.log("locked after 26 weeks (API3)", lockedHalf / 1e18);
        console.log("withdrawn total (API3)      ", (unstaked - vesting) / 1e18);
    }

    // ---------------------------------------------------------------- new stakers

    function test_06_new_user_deposits_stakes_and_exits() public {
        address user = makeAddr("newStaker");
        uint256 amount = 1_000_000e18;
        vm.prank(TREASURY_SAFE);
        API3.transfer(user, amount);

        vm.startPrank(user);
        API3.approve(address(POOL), amount);
        POOL.depositAndStake(amount);
        vm.stopPrank();
        assertApproxEqRel(POOL.userStake(user), amount, 1e12, "stake recorded");
        assertEq(API3.balanceOf(user), 0);

        _nextEpoch();
        uint256 staked = POOL.userStake(user);
        vm.prank(user);
        POOL.scheduleUnstake(staked);
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.roll(block.number + 1 weeks / 12);
        uint256 unstaked = POOL.unstake(user);
        assertEq(POOL.userLocked(user), 0, "no rewards were minted, so nothing is locked");

        vm.prank(user);
        POOL.withdrawRegular(unstaked);
        assertApproxEqRel(API3.balanceOf(user), amount, 1e12, "user got the deposit back");
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "supply untouched by staking");
    }

    /// The full life of a staker after the shutdown: halfStake exit, re-entry, full exit a year later.
    function test_08_staker_partially_exits_reenters_and_fully_exits_a_year_later() public {
        address staker = _stakerWithoutPendingUnstake();
        // Deposits made through the old TimelockManager stay in the pool until that contract releases them, which
        // is independent of the reward lock. Zero for the current voter set.
        (, uint256 timelocked,,,,,) = POOL.getUser(staker);
        uint256 walletBefore = API3.balanceOf(staker);

        // 1. Two reward epochs pass, one after 7 days and another 10 days later.
        _passDays(7);
        _passDays(10);

        // 2. Schedule a partial unstake. This is the first call into the pool since the shutdown, so it is also
        // the first reward mint attempt with the minter status gone.
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 halfStake = stakeBefore / 2;
        vm.prank(staker);
        POOL.scheduleUnstake(halfStake);
        assertEq(POOL.epochIndexOfLastReward(), block.timestamp / EPOCH, "cursor advanced without minting");
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "nothing minted");

        // 3. An epoch passes, which also matures the unstake.
        _passDays(7);

        // 4. Unstake.
        uint256 unstaked = POOL.unstake(staker);
        assertApproxEqRel(unstaked, halfStake, 1e12, "unstake returns the scheduled amount");
        assertApproxEqRel(POOL.userStake(staker), stakeBefore - halfStake, 1e12, "the rest stays staked");

        // 5. Withdraw what is not locked.
        uint256 withdrawn = _withdrawUnlocked(staker);
        assertGt(withdrawn, 0, "something was withdrawable");
        assertEq(API3.balanceOf(staker), walletBefore + withdrawn, "withdrawn to the wallet");

        // 6. An epoch passes.
        _passDays(7);

        // 7. Deposit it back and 8. stake it.
        vm.startPrank(staker);
        API3.approve(address(POOL), withdrawn);
        POOL.depositRegular(withdrawn);
        POOL.stake(withdrawn);
        vm.stopPrank();
        assertEq(API3.balanceOf(staker), walletBefore, "wallet back where it started");

        // 9. An epoch passes after 20 days.
        _passDays(20);

        // 10. Schedule an unstake of everything.
        uint256 stakeAll = POOL.userStake(staker);
        vm.prank(staker);
        POOL.scheduleUnstake(stakeAll);

        // 11. A year of epochs passes.
        for (uint256 i; i < 52; i++) {
            _nextEpoch();
        }

        // 12. Unstake and withdraw everything.
        uint256 unstakedAll = POOL.unstake(staker);
        assertApproxEqRel(unstakedAll, stakeAll, 1e12, "unstake returns everything staked");
        assertLt(POOL.userStake(staker), 1e6, "only rounding dust of stake is left");
        assertEq(POOL.userLocked(staker), 0, "no reward is locked a year after the last mint");
        (uint256 unstakedTotal,,,,,,) = POOL.getUser(staker);
        vm.prank(staker);
        POOL.withdrawRegular(unstakedTotal - timelocked);
        (uint256 unstakedAfter,,,,,,) = POOL.getUser(staker);
        assertEq(unstakedAfter, timelocked, "only a TimelockManager deposit can remain");
        assertEq(API3.balanceOf(staker), walletBefore + unstakedTotal - timelocked, "everything is in the wallet");
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "supply untouched throughout");
        console.log("staker                    ", staker);
        console.log("half unstake (API3)        ", halfStake / 1e18);
        console.log("withdrawn early (API3)    ", withdrawn / 1e18);
        console.log("withdrawn at the end (API3)", (unstakedTotal - timelocked) / 1e18);
    }

    function _passDays(uint256 numDays) internal {
        vm.warp(block.timestamp + numDays * 1 days + 1);
        vm.roll(block.number + numDays * 1 days / 12);
    }

    /// Withdraws the largest amount the pool allows, bounded by the unstaked balance and by the locked rewards and
    /// vesting that have to stay covered by the user's total funds.
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

    // ---------------------------------------------------------------- root permissions

    function test_07_root_permissions_are_gone() public {
        assertFalse(ACL.hasPermission(address(VOTING), address(ACL), CREATE_PERMISSIONS_ROLE), "no permission creator");
        assertEq(
            ACL.getPermissionManager(address(ACL), CREATE_PERMISSIONS_ROLE),
            address(0),
            "permission creation has no manager"
        );
        assertFalse(ACL.hasPermission(address(VOTING), address(KERNEL), APP_MANAGER_ROLE), "no app manager");
        assertEq(
            ACL.getPermissionManager(address(KERNEL), APP_MANAGER_ROLE), address(0), "app management has no manager"
        );

        // The primary voting app was the only holder, so a vote that somehow executes is the
        // strongest caller there is. Row 10 left vote creation without a manager, which is the
        // state createPermission needs, and it still fails.
        vm.startPrank(address(VOTING));
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        ACL.createPermission(VAULT, address(VOTING), CREATE_VOTES_ROLE, VAULT);
        bytes32 votingAppId = keccak256("api3voting");
        vm.expectRevert(bytes("KERNEL_AUTH_FAILED"));
        KERNEL.setApp(APP_BASES_NAMESPACE, votingAppId, address(POOL));
        vm.stopPrank();
    }
}

/// The fallback path: the pool mints one more epoch before the decided vote is executed, so the
/// supply overshoots by that reward and the Treasury Safe burns the surplus afterwards.
contract ShutdownProposalLateExecutionTest is ShutdownProposalBase {
    uint256 overshoot;

    function _execute() internal override {
        _nextEpoch();
        POOL.mintReward();
        VOTING.executeVote(voteId);
        overshoot = API3.totalSupply() - TARGET_SUPPLY;
        assertGt(overshoot, 0, "one more epoch was minted while the vote was open");
        vm.startPrank(TREASURY_SAFE);
        API3.updateBurnerStatus(true);
        API3.burn(overshoot);
        vm.stopPrank();
    }

    function test_01_overshoot_is_burned_and_supply_is_exactly_200M() public view {
        _assertOutcome();
        assertEq(
            API3.balanceOf(TREASURY_SAFE),
            treasuryApi3Before + mintAmount + agentApi3 - overshoot,
            "the Treasury Safe paid the burn"
        );
        console.log("overshoot burned (API3)", overshoot / 1e18);
    }
}
