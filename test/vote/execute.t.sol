// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {console} from "forge-std/Test.sol";
import {Base_Test} from "../Base.t.sol";

/// What executing the vote leaves behind, on the intended path and on the fallback path.
contract Vote_Execute_Test is Base_Test {
    function test_WhenTheVoteExecutesWithinTheEpochItWasPostedIn() external {
        // it should land the total supply on exactly 200,000,000 API3.
        // it should make the dead address the token owner and leave no minter.
        // it should empty the primary Agent into the Treasury Safe.
        // it should empty the secondary Agent into the Agent Safe.
        // it should credit the Treasury Safe with the mint and the primary Agent's API3.
        executeNow();
        _assertOutcome();
        assertEq(
            API3.balanceOf(TREASURY_SAFE),
            treasuryApi3Before + amounts.mint + amounts.agentApi3,
            "the Treasury Safe received the mint and the agent treasury"
        );
        console.log("minted by the vote (API3)    ", amounts.mint / 1e18);
        console.log("agent treasury moved (API3)  ", amounts.agentApi3 / 1e18);
        console.log("secondary agent USDC moved   ", amounts.secondaryUsdc / 1e6);
    }

    function test_WhenOneMoreRewardEpochIsMintedBeforeTheVoteExecutes() external {
        // it should overshoot the target by that epoch's reward.
        // it should land on exactly 200,000,000 API3 once the Agent Safe burns the overshoot.
        // it should have the Treasury Safe cover only what the Agent Safe lacked.
        uint256 supplyBefore = API3.totalSupply();
        uint256 agentSafeApi3Before = API3.balanceOf(AGENT_SAFE);
        (uint256 overshoot, uint256 reward, uint256 shortfall) = executeAfterOneMoreEpoch();
        assertGt(reward, 0, "one more epoch was minted while the vote was open");
        // Plus whatever the supply grew by since the amounts were read, nothing when the script was built here
        assertEq(
            overshoot, reward + supplyBefore + amounts.mint - TARGET_SUPPLY, "the overshoot is that epoch's reward"
        );
        _assertOutcome();
        assertEq(
            API3.balanceOf(AGENT_SAFE), agentSafeApi3Before + shortfall - overshoot, "the Agent Safe burned the excess"
        );
        assertEq(
            API3.balanceOf(TREASURY_SAFE),
            treasuryApi3Before + amounts.mint + amounts.agentApi3 - shortfall,
            "the Treasury Safe covered the shortfall and nothing more"
        );
        console.log("overshoot burned (API3)        ", overshoot / 1e18);
        console.log("Agent Safe API3 before (API3)  ", agentSafeApi3Before / 1e18);
        console.log("Treasury Safe top-up (API3)    ", shortfall / 1e18);
    }

    function test_WhenAHolderBurnsAPI3BeforeTheVoteExecutes() external {
        // it should land below the target by the burned amount with no minter left to make it up.
        // Burning is self-service for any holder, the Vault Safe stands in for one here
        uint256 burned = 1_000e18;
        vm.startPrank(VAULT);
        API3.updateBurnerStatus(true);
        API3.burn(burned);
        vm.stopPrank();
        executeNow();
        assertEq(API3.totalSupply(), TARGET_SUPPLY - burned, "the supply lands short by the burn");
        assertEq(API3.owner(), DEAD, "token owner is the dead address");
        assertFalse(API3.getMinterStatus(address(POOL)), "pool cannot mint");
        assertFalse(API3.getMinterStatus(address(AGENT)), "agent cannot mint");
        vm.prank(VAULT);
        vm.expectRevert();
        API3.updateMinterStatus(VAULT, true);
    }
}
