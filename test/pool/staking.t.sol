// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {console} from "forge-std/Test.sol";
import {Executed_Test} from "../Base.t.sol";

/// Stakers keep every right but voting: unstaking and withdrawing work unchanged and locked rewards unlock on the
/// same schedule.
contract Pool_Staking_Test is Executed_Test {
    function test_WhenAnExistingStakerSchedulesAFullUnstakeAndUnstakesAfterSevenDays() external {
        // it should return the staked amount with only rounding dust left.
        // it should refuse to withdraw one wei more than the unlocked part.
        // it should withdraw everything that is not locked or vesting.
        address staker = _stakerWithoutPendingUnstake();
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 lockedBefore = POOL.userLocked(staker);
        (uint256 unstakedBefore, uint256 vesting,,,,,) = POOL.getUser(staker);
        assertGt(stakeBefore, 0, "staker has stake");
        assertGt(lockedBefore, 0, "staker has locked rewards");

        vm.prank(staker);
        POOL.scheduleUnstake(stakeBefore);
        _passDays(7);
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

    function test_WhenRewardEpochsKeepPassingAfterAnExistingStakerUnstaked() external {
        // it should hold less locked after 26 epochs than at the start.
        // it should hold nothing locked after 52 epochs.
        // it should let the staker withdraw everything but the timelocked vesting.
        address staker = _stakerWithoutPendingUnstake();
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 lockedStart = POOL.userLocked(staker);
        (, uint256 vesting,,,,,) = POOL.getUser(staker);
        assertGt(lockedStart, 0);

        vm.prank(staker);
        POOL.scheduleUnstake(stakeBefore);
        _passDays(7);
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

    function test_WhenANewAddressDepositsAndStakesAfterTheMigration() external {
        // it should record the stake.
        // it should let it unstake after seven days with nothing locked.
        // it should return the full deposit on withdrawal.
        // it should leave the total supply untouched.
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
        _passDays(7);
        uint256 unstaked = POOL.unstake(user);
        assertEq(POOL.userLocked(user), 0, "no rewards were minted, so nothing is locked");

        vm.prank(user);
        POOL.withdrawRegular(unstaked);
        assertApproxEqRel(API3.balanceOf(user), amount, 1e12, "user got the deposit back");
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "supply untouched by staking");
    }

    function test_WhenAnExistingStakerExitsHalfThenComesBackAndExitsFullyAYearLater() external {
        // it should advance the reward cursor without minting on the first call after the migration.
        // it should return the scheduled half and keep the rest staked.
        // it should withdraw the unlocked part and take the same amount back as stake.
        // it should hold nothing locked a year after the last mint and withdraw everything, except the vesting API3 the old TimelockManager contract deposited for the staker.
        address staker = _stakerWithoutPendingUnstake();
        // The TimelockManager is the contract that held the vesting API3 of early recipients and deposited it in the pool
        // for them. The pool holds it as vesting until `updateTimelockStatus` releases it on the timelock's schedule,
        // independently of the reward lock. Anyone can call that for any user, the test does not. Zero for the current
        // voter set.
        (, uint256 timelocked,,,,,) = POOL.getUser(staker);
        uint256 walletBefore = API3.balanceOf(staker);

        // Two reward epochs pass, one after 7 days and another 10 days later.
        _passDays(7);
        _passDays(10);

        // Schedule a partial unstake. This is the first call into the pool since the migration, so it is also the
        // first reward mint attempt with the minter status gone.
        uint256 stakeBefore = POOL.userStake(staker);
        uint256 halfStake = stakeBefore / 2;
        vm.prank(staker);
        POOL.scheduleUnstake(halfStake);
        assertEq(POOL.epochIndexOfLastReward(), block.timestamp / EPOCH, "cursor advanced without minting");
        assertEq(API3.totalSupply(), TARGET_SUPPLY, "nothing minted");

        // An epoch passes, which also matures the unstake.
        _passDays(7);
        uint256 unstaked = POOL.unstake(staker);
        assertApproxEqRel(unstaked, halfStake, 1e12, "unstake returns the scheduled amount");
        assertApproxEqRel(POOL.userStake(staker), stakeBefore - halfStake, 1e12, "the rest stays staked");

        // Withdraw what is not locked.
        uint256 withdrawn = _withdrawUnlocked(staker);
        assertGt(withdrawn, 0, "something was withdrawable");
        assertEq(API3.balanceOf(staker), walletBefore + withdrawn, "withdrawn to the wallet");

        // An epoch passes, then the same amount goes back in as stake.
        _passDays(7);
        vm.startPrank(staker);
        API3.approve(address(POOL), withdrawn);
        POOL.depositRegular(withdrawn);
        POOL.stake(withdrawn);
        vm.stopPrank();
        assertEq(API3.balanceOf(staker), walletBefore, "wallet back where it started");

        // An epoch passes after 20 days, then everything is scheduled for unstaking.
        _passDays(20);
        uint256 stakeAll = POOL.userStake(staker);
        vm.prank(staker);
        POOL.scheduleUnstake(stakeAll);

        // A year of epochs passes.
        for (uint256 i; i < 52; i++) {
            _nextEpoch();
        }

        // Unstake and withdraw everything.
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
}
