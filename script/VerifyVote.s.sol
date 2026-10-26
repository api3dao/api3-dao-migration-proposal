// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/ShutdownScript.sol";

/// @notice Checks a posted vote against the source: rebuilds the script at the vote's snapshot block, the way
/// `CreateVote.s.sol` built it for posting, and the metadata from `proposal/title.txt` and `proposal/description.md`,
/// then compares both with what the primary voting app holds for the vote and with its StartVote log, which also has
/// to name the Vault Safe as the creator. The vote is the tested thing when this passes, since the fork tests run on
/// the script the same source builds. Read-only.
///
///   forge script script/VerifyVote.s.sol --sig "run(uint256)" <vote id>
///
/// The vote id is the number in the proposal's DAO dashboard URL, `primary-<vote id>`.
contract VerifyVote is Script, ShutdownScript {
    bytes32 constant START_VOTE_TOPIC = keccak256("StartVote(uint256,address,string)");

    function run(uint256 voteId) external {
        require(voteId < VOTING.votesLength(), "VerifyVote: no vote with this id has been posted yet");
        (bool open, bool executed,, uint64 snapshotBlock,,,,,, bytes memory posted) = VOTING.getVote(voteId);
        console.log("vote", voteId, executed ? "executed" : open ? "open" : "closed", "snapshot block");
        console.log(snapshotBlock);

        // The amounts in the script are balances, so the source is run at the block the vote reads its state from.
        // The Vault builds and posts in one sitting, so nothing moves in between.
        vm.rollFork(snapshotBlock);
        bytes memory expected = buildScript(readAmounts());
        require(
            keccak256(posted) == keccak256(expected),
            "VerifyVote: the source at the vote's snapshot block builds a different script than the vote holds"
        );
        console.log("the posted script is the one the source builds, bytes:", posted.length);
        console.log("keccak256", vm.toString(keccak256(posted)));

        // `getVote` returns neither the creator nor the metadata, only the StartVote log has them. A vote's snapshot
        // block is the block before the one it was created in, so the log is in the block after it.
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = START_VOTE_TOPIC;
        topics[1] = bytes32(voteId);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(snapshotBlock + 1, snapshotBlock + 1, address(VOTING), topics);
        require(logs.length == 1, "VerifyVote: no StartVote log for the vote in the block after its snapshot");
        require(
            address(uint160(uint256(logs[0].topics[2]))) == VAULT, "VerifyVote: the Vault Safe did not create the vote"
        );
        string memory title = vm.readLine("proposal/title.txt");
        string memory metadata = buildMetadata(title, vm.trim(vm.readFile("proposal/description.md")));
        require(
            keccak256(bytes(abi.decode(logs[0].data, (string)))) == keccak256(bytes(metadata)),
            "VerifyVote: the vote's metadata is not the one built from proposal/title.txt and proposal/description.md"
        );
        console.log("created by the Vault Safe with the metadata built from the proposal files");
        console.log("VERIFIED");
    }
}
