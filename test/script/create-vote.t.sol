// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CreateVote} from "../../script/CreateVote.s.sol";

contract Create_Vote_Test is Test, CreateVote {
    function test_ShouldPreserveEveryGeneratedAmountAsADecimalString() external {
        // it should preserve every generated amount as a decimal string.
        // JSON numbers lose this wei when parsed by JavaScript, which rounds 2**53 + 1 to 2**53.
        Amounts memory expected =
            Amounts({mint: TARGET_SUPPLY, agentApi3: 1, secondaryUsdc: type(uint256).max, secondaryEth: 2 ** 53 + 1});
        string memory json = _amountsJson(expected);
        assertEq(vm.parseJsonUint(json, ".block"), block.number);
        _assertDecimalString(json, "mint", expected.mint);
        _assertDecimalString(json, "agentApi3", expected.agentApi3);
        _assertDecimalString(json, "secondaryUsdc", expected.secondaryUsdc);
        _assertDecimalString(json, "secondaryEth", expected.secondaryEth);
    }

    function _assertDecimalString(string memory json, string memory key, uint256 expected) internal pure {
        // Foundry's JSON parsers coerce decimal strings and numbers, so check the quotes in the output too.
        string memory compact = vm.replace(json, " ", "");
        assertTrue(
            vm.contains(compact, string.concat('"', key, '":"', vm.toString(expected), '"')),
            string.concat(key, " must be a decimal string")
        );
        assertEq(vm.parseJsonUint(json, string.concat(".", key)), expected);
    }
}
