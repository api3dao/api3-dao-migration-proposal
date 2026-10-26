// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/ShutdownScript.sol";

/// @notice Checks the posted vote against the committed files: the script the primary voting app holds for it equals
/// `proposal/generated/script.hex` byte for byte and the Vault Safe created it with `proposal/generated/metadata.txt`.
/// Those files are what the fork tests run on (`GENERATED_DIR=proposal/generated forge test`) and what the source
/// builds at their block, so this is the last link: the vote on the chain is the tested one. While the vote is open it
/// also reports whether the balances the script moves still cover the amounts in it, since a shortfall would make
/// the whole script revert at execution. Read-only.
///
/// `forge script script/VerifyVote.s.sol` takes the vote id from `proposal/vote-id.txt`, committed when the vote is
/// posted. `--sig "check(uint256)" <id>` names one instead.
contract VerifyVote is Script, ShutdownScript {
    bytes32 constant START_VOTE_TOPIC = keccak256("StartVote(uint256,address,string)");

    function run() external view {
        require(vm.exists("proposal/vote-id.txt"), "VerifyVote: no vote posted yet, proposal/vote-id.txt is missing");
        check(vm.parseUint(vm.trim(vm.readFile("proposal/vote-id.txt"))));
    }

    function check(uint256 voteId) public view {
        bytes memory script_ = vm.parseBytes(vm.readFile("proposal/generated/script.hex"));
        string memory metadata = vm.readFile("proposal/generated/metadata.txt");

        (bool open, bool executed,, uint64 snapshotBlock,,,,,, bytes memory onChain) = VOTING.getVote(voteId);
        require(
            keccak256(onChain) == keccak256(script_),
            "VerifyVote: the vote's script is not proposal/generated/script.hex"
        );
        console.log("vote", voteId, "holds the committed script,", script_.length);
        console.log("bytes, keccak256", vm.toString(keccak256(script_)));

        // `getVote` returns neither the creator nor the metadata, only the StartVote log has them. A vote's snapshot
        // block is the block before the one it was created in, so the log is in the block after it.
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = START_VOTE_TOPIC;
        topics[1] = bytes32(voteId);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(snapshotBlock + 1, snapshotBlock + 1, address(VOTING), topics);
        require(logs.length == 1, "VerifyVote: no StartVote log for the vote in the block after its snapshot");
        address creator = address(uint160(uint256(logs[0].topics[2])));
        require(creator == VAULT, "VerifyVote: the Vault Safe did not create the vote");
        require(
            keccak256(bytes(abi.decode(logs[0].data, (string)))) == keccak256(bytes(metadata)),
            "VerifyVote: the vote's metadata is not proposal/generated/metadata.txt"
        );
        console.log("created by the Vault Safe with the committed metadata, snapshot block", snapshotBlock);

        if (executed) {
            console.log("the vote is executed");
        } else {
            console.log(open ? "the vote is open" : "the vote is closed, not executed");
            _reportAmounts();
        }
        console.log("VERIFIED");
    }

    /// The amounts in the script are the balances when the bytes were built. A balance that fell since makes the
    /// whole script revert at execution. A supply that grew is the rehearsed fallback: the Treasury Safe burns the
    /// overshoot after execution.
    function _reportAmounts() internal view {
        string memory json = vm.readFile("proposal/generated/amounts.json");
        uint256 mint = vm.parseJsonUint(json, ".mint");
        uint256 supply = API3.totalSupply();
        if (supply == TARGET_SUPPLY - mint) {
            console.log("the supply is as it was when the bytes were built, the mint lands on the target");
        } else {
            console.log(
                "the supply grew since the bytes were built, the mint overshoots by", supply + mint - TARGET_SUPPLY
            );
        }
        _covered("primary Agent API3", API3.balanceOf(address(AGENT)), vm.parseJsonUint(json, ".agentApi3"));
        _covered(
            "secondary Agent USDC", USDC.balanceOf(address(AGENT_SECONDARY)), vm.parseJsonUint(json, ".secondaryUsdc")
        );
        _covered(
            "secondary Agent PNK", PNK.balanceOf(address(AGENT_SECONDARY)), vm.parseJsonUint(json, ".secondaryPnk")
        );
        _covered(
            "secondary Agent wPOKT",
            WPOKT.balanceOf(address(AGENT_SECONDARY)),
            vm.parseJsonUint(json, ".secondaryWpokt")
        );
        _covered("secondary Agent ETH", address(AGENT_SECONDARY).balance, vm.parseJsonUint(json, ".secondaryEth"));
    }

    function _covered(string memory what, uint256 balance, uint256 amount) internal pure {
        require(balance >= amount, string.concat("VerifyVote: ", what, " fell below the amount in the script"));
        console.log(
            what,
            balance == amount ? "is the amount in the script" : "exceeds the amount in the script by",
            balance - amount
        );
    }
}
