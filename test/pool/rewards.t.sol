// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Executed_Test} from "../Base.t.sol";

/// The pool's reward clock after the minter status is gone.
contract Pool_Rewards_Test is Executed_Test {
    function test_WhenRewardEpochsPassAfterTheShutdown() external {
        // it should mint nothing on mintReward.
        // it should leave the total stake unchanged.
        // it should keep advancing the epoch cursor.
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
}
