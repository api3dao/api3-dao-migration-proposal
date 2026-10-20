// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Vm, console} from "forge-std/Test.sol";
import {Base_Test} from "../Base.t.sol";

/// The vote that takes yea past half of all voting power. The dashboard casts votes with `executesIfDecided`, so that
/// voter's transaction runs the whole script, and if the script reverts so does their vote.
contract Vote_Crossing_Test is Base_Test {
    address constant PAYEE = address(0xBEEF);

    constructor() {
        stopOneShort = true;
    }

    function test_WhenTheCrossingVoterVotesWithExecutesIfDecided() external {
        // it should execute the script in that same transaction.
        vm.prank(crossingVoter);
        VOTING.vote(voteId, true, true);
        Vm.Gas memory gas = vm.lastFrameGas();
        (, bool executed,,,,,,,,) = VOTING.getVote(voteId);
        assertTrue(executed, "executed within the crossing vote");
        _nextBlock();
        _assertOutcome();
        console.log("crossing vote gas", gas.gasTotalUsed);
    }

    function test_WhenTheCrossingVoterVotesWithoutExecutesIfDecided() external {
        // it should leave the vote for anyone to execute.
        vm.prank(crossingVoter);
        VOTING.vote(voteId, true, false);
        (, bool executed,,,,,,,,) = VOTING.getVote(voteId);
        assertFalse(executed, "not executed by the vote");
        assertTrue(VOTING.canExecute(voteId), "decided");
        vm.prank(address(0xA11CE));
        VOTING.executeVote(voteId);
        _nextBlock();
        _assertOutcome();
    }

    function test_WhenATokenBalanceOfTheSecondaryAgentFellAfterTheBytesWereBuilt() external {
        // it should revert the crossing vote cast with executesIfDecided.
        // it should accept the crossing vote cast without it and leave the vote decided.
        // it should revert executeVote until the balance is restored.
        // A payout from the secondary Agent after the bytes were built, say through a secondary vote
        vm.prank(address(AGENT_SECONDARY));
        USDC.transfer(PAYEE, 1);

        vm.prank(crossingVoter);
        vm.expectRevert(bytes("VAULT_TOKEN_TRANSFER_REVERTED"));
        VOTING.vote(voteId, true, true);

        vm.prank(crossingVoter);
        VOTING.vote(voteId, true, false);
        assertTrue(VOTING.canExecute(voteId), "decided all the same");
        vm.expectRevert(bytes("VAULT_TOKEN_TRANSFER_REVERTED"));
        VOTING.executeVote(voteId);

        // Anyone restoring the balance unblocks the decided vote
        vm.prank(PAYEE);
        USDC.transfer(address(AGENT_SECONDARY), 1);
        VOTING.executeVote(voteId);
        _nextBlock();
        _assertOutcome();
    }
}
