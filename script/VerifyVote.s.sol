// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/MigrationScript.sol";

/// @notice Checks a posted vote against the source: rebuilds the script at the vote's snapshot block, the way
/// `CreateVote.s.sol` built it for posting, and the metadata from `proposal/title.txt` and `proposal/description.md`,
/// then compares both with what the primary voting app holds for the vote and with its StartVote log, which also has
/// to name the Vault Safe as the creator. The vote is the tested thing when this passes, since the fork tests run on
/// the script the same source builds. Read-only.
///
///   forge script script/VerifyVote.s.sol --sig "run(uint256)" <VOTE_ID>
///   forge script script/VerifyVote.s.sol --sig "run(uint256,uint256)" <VOTE_ID> <BUILD_BLOCK>
///
/// The vote id is the number in the proposal's DAO dashboard URL, `primary-<VOTE_ID>`. The bytes carry four balances
/// read when they were built, so one wei of API3 burned, or of USDC or ETH sent to the secondary Agent, between the
/// build and the posting changes what the source builds at the snapshot block and fails the first form. The second
/// form takes the block the bytes were built at, `block` in the `proposal/generated/amounts.json` that
/// `CreateVote.s.sol` wrote, rebuilds the script there and prints which of the four amounts moved between the build
/// and the snapshot block, and by how much. The vote is then still exactly what the source built, with the amounts of
/// the build block.
contract VerifyVote is Script, MigrationScript {
    bytes32 constant START_VOTE_TOPIC = keccak256("StartVote(uint256,address,string)");

    function run(uint256 voteId) external {
        _verify(voteId, 0);
    }

    function run(uint256 voteId, uint256 buildBlock) external {
        require(buildBlock > 0, "VerifyVote: the build block is the one in proposal/generated/amounts.json");
        _verify(voteId, buildBlock);
    }

    function _verify(uint256 voteId, uint256 buildBlock) internal {
        require(voteId < VOTING.votesLength(), "VerifyVote: no vote with this id has been posted yet");
        (bool open, bool executed,, uint64 snapshotBlock,,,,,, bytes memory posted) = VOTING.getVote(voteId);
        console.log("vote", voteId, executed ? "executed" : open ? "open" : "closed", "snapshot block");
        console.log(snapshotBlock);

        // The amounts in the script are balances, so the source is run at the block the vote reads its state from.
        // The Vault builds and posts in one sitting, so nothing moves in between unless a third party moves it.
        vm.rollFork(snapshotBlock);
        Amounts memory atSnapshot = readAmounts();
        if (keccak256(posted) == keccak256(buildScript(atSnapshot))) {
            console.log("the posted script is the one the source builds at the snapshot block, bytes:", posted.length);
        } else {
            require(
                buildBlock != 0,
                "VerifyVote: the source at the vote's snapshot block builds a different script than the vote holds. If a balance moved between the build and the posting, rerun as run(uint256,uint256) with the block the bytes were built at"
            );
            require(buildBlock <= snapshotBlock, "VerifyVote: the build block has to be before the snapshot block");
            vm.rollFork(buildBlock);
            Amounts memory atBuild = readAmounts();
            _report(atBuild, atSnapshot);
            require(
                keccak256(posted) == keccak256(buildScript(atBuild)),
                "VerifyVote: the source builds a different script than the vote holds at the build block as well"
            );
            console.log("the posted script is the one the source builds at the build block, bytes:", posted.length);
            console.log(
                "the amounts marked moved changed between the build and the posting, the vote carries the build's"
            );
        }
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

    /// The four amounts at the build block next to the ones at the snapshot block, "moved" where they differ.
    function _report(Amounts memory atBuild, Amounts memory atSnapshot) internal pure {
        console.log("amount: at the build block, at the snapshot block");
        _line("mint, API3 wei", atBuild.mint, atSnapshot.mint);
        _line("primary Agent API3, wei", atBuild.agentApi3, atSnapshot.agentApi3);
        _line("secondary Agent USDC, 6 decimals", atBuild.secondaryUsdc, atSnapshot.secondaryUsdc);
        _line("secondary Agent ETH, wei", atBuild.secondaryEth, atSnapshot.secondaryEth);
    }

    function _line(string memory name, uint256 atBuild, uint256 atSnapshot) internal pure {
        if (atBuild == atSnapshot) {
            console.log(name, atBuild, "unchanged");
        } else {
            console.log(name, atBuild, atSnapshot, atBuild < atSnapshot ? "moved up" : "moved down");
        }
    }
}
