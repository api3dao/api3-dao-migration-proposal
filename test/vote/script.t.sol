// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Base_Test} from "../Base.t.sol";
import {IAgent} from "../../src/Interfaces.sol";

/// The bytes themselves, before anything is executed.
contract Vote_Script_Test is Base_Test {
    bytes4 constant CALLS_SCRIPT_SPEC_ID = 0x00000001;
    uint256 constant CALLS = 28;
    bytes1 constant DELIMITER = 0x1f;

    function test_ShouldStartWithTheCallsScriptSpecIdAndHold28Calls() external view {
        // it should start with the CallsScript spec id and hold 28 calls.
        assertEq(bytes4(script), CALLS_SCRIPT_SPEC_ID, "spec id");
        (address[] memory targets,) = this.parse(script);
        assertEq(targets.length, CALLS, "number of calls");
    }

    function test_ShouldCallTheACLAndThePrimaryAgentDirectlyAndEverythingElseThroughThePrimaryAgent() external view {
        // it should call the ACL and the primary Agent directly and everything else through the primary Agent.
        (address[] memory targets, bytes4[] memory selectors) = this.parse(script);
        uint256 direct;
        uint256 viaAgent;
        for (uint256 i; i < targets.length; i++) {
            if (targets[i] == address(ACL)) {
                direct++;
                continue;
            }
            assertEq(targets[i], address(AGENT), "every call not on the ACL goes to the primary Agent");
            assertTrue(
                selectors[i] == IAgent.execute.selector || selectors[i] == IAgent.transfer.selector,
                "the primary Agent is only ever asked to execute or to transfer"
            );
            viaAgent++;
        }
        assertGt(direct, 0, "the ACL is called directly");
        assertGt(viaAgent, 0, "the primary Agent forwards the rest");
    }

    function test_ShouldCarryVersion3MetadataWithTheTitleAndTheDescription() external view {
        // it should carry version 3 metadata with the title and the description.
        bytes memory m = bytes(metadata);
        assertEq(m[0], bytes1("3"), "version 3");
        assertEq(m[1], DELIMITER, "delimiter after the version");
        uint256 delimiters;
        uint256 second;
        for (uint256 i; i < m.length; i++) {
            if (m[i] != DELIMITER) continue;
            delimiters++;
            if (delimiters == 2) second = i;
        }
        assertEq(delimiters, 2, "version, title and description, nothing else");
        assertGt(second, 2, "the title is not empty");
        assertGt(m.length, second + 1, "the description is not empty");
    }

    function test_GivenTheSecondaryAgentHoldsNoneOfATokenTheScriptMoves() external {
        // it should refuse to build the bytes.
        // Aragon's Vault reverts on a zero transfer, which would take the whole script down with it
        uint256 balance = USDC.balanceOf(address(AGENT_SECONDARY));
        vm.prank(address(AGENT_SECONDARY));
        USDC.transfer(address(0xBEEF), balance);
        vm.expectRevert(bytes("ShutdownScript: no USDC to move"));
        this.build();
    }

    function build() external view returns (bytes memory) {
        return buildScript(readAmounts());
    }

    function test_GivenAGeneratedScriptDirectoryIsNamed() external {
        // it should equal the bytes the source builds at the block the amounts were read at.
        // it should carry the metadata built from proposal/title.txt and proposal/description.md.
        // it should move the API3 to a Treasury Safe that is deployed.
        if (bytes(generatedDir).length == 0) vm.skip(true);
        assertEq(buildScript(readAmounts()), script, "script.hex against the source at its block");
        string memory title = vm.readLine("proposal/title.txt");
        vm.closeFile("proposal/title.txt");
        assertEq(buildMetadata(title, vm.readFile("proposal/description.md")), metadata, "metadata.txt");
        assertGt(TREASURY_SAFE.code.length, 0, "the Treasury Safe is deployed");
    }

    /// Walks a CallsScript: the 4 byte spec id, then entries of a 20 byte target, a 4 byte calldata length and the
    /// calldata. External so that calldata slices do the parsing.
    function parse(bytes calldata data) external pure returns (address[] memory targets, bytes4[] memory selectors) {
        require(bytes4(data[:4]) == CALLS_SCRIPT_SPEC_ID, "not a CallsScript");
        uint256 count;
        for (uint256 i = 4; i < data.length; count++) {
            i += 24 + uint32(bytes4(data[i + 20:i + 24]));
        }
        targets = new address[](count);
        selectors = new bytes4[](count);
        uint256 index;
        for (uint256 i = 4; i < data.length; index++) {
            targets[index] = address(bytes20(data[i:i + 20]));
            uint256 length = uint32(bytes4(data[i + 20:i + 24]));
            selectors[index] = bytes4(data[i + 24:i + 28]);
            i += 24 + length;
        }
    }
}
