// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/ShutdownScript.sol";

/// @notice Builds the vote script and metadata from the chain state at the current block and writes them to
/// `proposal/generated/`: the bytes, their keccak256 hash, the metadata string and the amounts they contain. The
/// title and description come from `proposal/title.txt` and `proposal/description.md`.
///
/// Without `--broadcast` nothing is sent, the `newVote` call is only simulated, which checks that the Vault Safe
/// clears the proposal threshold. Posting the real vote is a Vault Safe transaction, not this script.
contract CreateVote is Script, ShutdownScript {
    function run() external {
        // The bytes name the Treasury Safe as the destination of the API3. Nothing gets written, let alone posted, for
        // an address without code.
        require(TREASURY_SAFE.code.length > 0, "CreateVote: the Treasury Safe is not deployed");
        Amounts memory amounts = readAmounts();
        bytes memory script_ = buildScript(amounts);
        string memory title = vm.readLine("proposal/title.txt");
        // Without the file's trailing newline, so that the string has one spelling wherever it is rebuilt from the
        // files, by tools that trim their arguments as well as by ones that do not.
        string memory description = vm.trim(vm.readFile("proposal/description.md"));
        string memory metadata = buildMetadata(title, description);

        vm.writeFile("proposal/generated/script.hex", vm.toString(script_));
        // The DAO dashboard shows a proposal created outside of it only when the script's hash is one it knows
        vm.writeFile("proposal/generated/script-hash.txt", vm.toString(keccak256(script_)));
        vm.writeFile("proposal/generated/metadata.txt", metadata);
        string memory json = "amounts";
        vm.serializeUint(json, "block", block.number);
        vm.serializeUint(json, "mint", amounts.mint);
        vm.serializeUint(json, "agentApi3", amounts.agentApi3);
        vm.serializeUint(json, "secondaryUsdc", amounts.secondaryUsdc);
        vm.serializeUint(json, "secondaryPnk", amounts.secondaryPnk);
        vm.serializeUint(json, "secondaryWpokt", amounts.secondaryWpokt);
        vm.writeJson(vm.serializeUint(json, "secondaryEth", amounts.secondaryEth), "proposal/generated/amounts.json");

        console.log("block                     ", block.number);
        console.log("script bytes              ", script_.length);
        console.log("script hash               ", vm.toString(keccak256(script_)));
        console.log("mint (API3)               ", amounts.mint / 1e18);
        console.log("agent treasury (API3)     ", amounts.agentApi3 / 1e18);
        console.log("secondary agent USDC      ", amounts.secondaryUsdc / 1e6);
        console.log("written to proposal/generated/: script.hex, metadata.txt, script-hash.txt, amounts.json");

        // The Vault Safe posts without voting, so the posted bytes can be checked before any vote is cast.
        vm.startBroadcast(VAULT);
        uint256 voteId = VOTING.newVote(script_, metadata, false, false);
        vm.stopBroadcast();
        console.log("vote id                   ", voteId);
    }
}
