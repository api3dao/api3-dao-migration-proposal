// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {console} from "forge-std/Test.sol";
import {Base_Test} from "../Base.t.sol";

/// What executing the vote leaves behind, on the intended path and on the fallback path.
contract Vote_Execute_Test is Base_Test {
    function test_WhenTheVoteExecutesWithinTheEpochItWasPostedIn() external {
        // it should land the total supply on exactly 200,000,000 API3.
        // it should make the dead address the token owner and leave no minter.
        // it should empty the primary Agent into the Vault Safe.
        // it should empty the secondary Agent into the Agent Safe.
        // it should credit the Vault Safe with the mint and the primary Agent's API3.
        executeNow();
        _assertOutcome();
        assertEq(
            API3.balanceOf(VAULT),
            vaultApi3Before + amounts.mint + amounts.agentApi3,
            "vault received the mint and the agent treasury"
        );
        console.log("minted by the vote (API3)    ", amounts.mint / 1e18);
        console.log("agent treasury moved (API3)  ", amounts.agentApi3 / 1e18);
        console.log("secondary agent USDC moved   ", amounts.secondaryUsdc / 1e6);
    }

    function test_WhenOneMoreRewardEpochIsMintedBeforeTheVoteExecutes() external {
        // it should overshoot the target by that epoch's reward.
        // it should land on exactly 200,000,000 API3 once the Vault Safe burns the overshoot.
        uint256 supplyBefore = API3.totalSupply();
        (uint256 overshoot, uint256 reward) = executeAfterOneMoreEpoch();
        assertGt(reward, 0, "one more epoch was minted while the vote was open");
        // Plus whatever the supply grew by since the amounts were read, nothing when the script was built here
        assertEq(
            overshoot, reward + supplyBefore + amounts.mint - TARGET_SUPPLY, "the overshoot is that epoch's reward"
        );
        _assertOutcome();
        assertEq(
            API3.balanceOf(VAULT), vaultApi3Before + amounts.mint + amounts.agentApi3 - overshoot, "vault paid the burn"
        );
        console.log("overshoot burned (API3)", overshoot / 1e18);
    }
}
