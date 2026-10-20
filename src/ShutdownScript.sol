// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "./Interfaces.sol";

/// @notice The vote script of the primary proposal that winds down the legacy DAO, built the same way for the fork
/// tests and for the vote that gets posted. The script follows Appendix A of the proposal row by row, one Aragon
/// CallsScript with calls made by the primary voting app directly (ACL, primary Agent) or through the primary Agent's
/// `execute` (token, secondary Agent, voting apps).
///
/// The amounts the script moves are fixed when it is built, see `readAmounts`. Nothing here sends a transaction.
abstract contract ShutdownScript {
    IApi3Token constant API3 = IApi3Token(0x0b38210ea11411557c13457D4dA7dC6ea731B88a);
    IApi3Pool constant POOL = IApi3Pool(0x6dd655f10d4b9E242aE186D9050B68F725c76d76);
    IApi3Voting constant VOTING = IApi3Voting(0xDb6C812E439ce5c740570578681ea7aaDba5170b);
    IApi3Voting constant VOTING_SECONDARY = IApi3Voting(0x1c8058E72E4902B3431Ef057E8d9a58A73F26372);
    IAgent constant AGENT = IAgent(0xD9F80Bdb37E6Bad114D747E60cE6d2aaF26704Ae);
    IAgent constant AGENT_SECONDARY = IAgent(0x556ECbb0311D350491Ba0EC7E019c354D7723CE0);
    IACL constant ACL = IACL(0x1E7eCC6D3B5b4cfDfC71CB7C3eA9AC4A55F4195A);
    IKernel constant KERNEL = IKernel(0x593EA926ee9820A933488B6A288433C387D06dba);
    address constant VAULT = 0x8e03609ed680B237C7b6f8020472CA0687308b24;
    address constant AGENT_SAFE = 0xBBE0dE9757F93e3306aDBfeBE906AB285EDD13DA;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ANY_ENTITY = address(type(uint160).max);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant PNK = IERC20(0x93ED3FBe21207Ec2E8f2d3c3de6e058Cb73Bc04d);
    IERC20 constant WPOKT = IERC20(0x67F4C72a50f8Df6487720261E188F2abE83F57D7);

    bytes32 constant CREATE_VOTES_ROLE = keccak256("CREATE_VOTES_ROLE");
    bytes32 constant MODIFY_SUPPORT_ROLE = keccak256("MODIFY_SUPPORT_ROLE");
    bytes32 constant MODIFY_QUORUM_ROLE = keccak256("MODIFY_QUORUM_ROLE");
    bytes32 constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    bytes32 constant EXECUTE_ROLE = keccak256("EXECUTE_ROLE");
    bytes32 constant CREATE_PERMISSIONS_ROLE = keccak256("CREATE_PERMISSIONS_ROLE");
    bytes32 constant APP_MANAGER_ROLE = keccak256("APP_MANAGER_ROLE");
    bytes32 constant APP_BASES_NAMESPACE = keccak256("base");

    uint256 constant TARGET_SUPPLY = 200_000_000e18;
    uint256 constant EPOCH = 1 weeks;
    uint64 constant PCT_BASE = 1e18;
    uint64 constant MAX_PCT = PCT_BASE - 1;

    /// The separator of the DAO dashboard's metadata scheme, and the version that tells it to decode the script on
    /// its own rather than from a single target signature.
    string constant METADATA_DELIMITER = "\x1f";
    string constant METADATA_VERSION = "3";

    /// What the script moves, read from the chain when the vote is built.
    struct Amounts {
        /// Minted into the Vault Safe, 200,000,000 API3 minus the total supply at that block.
        uint256 mint;
        /// The primary Agent's API3, moved to the Vault Safe.
        uint256 agentApi3;
        /// The secondary Agent's balances, moved to the agent multisig.
        uint256 secondaryUsdc;
        uint256 secondaryPnk;
        uint256 secondaryWpokt;
        uint256 secondaryEth;
    }

    /// Every amount has to be positive. Aragon's Vault refuses a zero transfer, and one reverting call reverts the
    /// whole script, so a row with nothing to move has to be dropped from the script rather than left in with a zero.
    function readAmounts() internal view returns (Amounts memory amounts) {
        uint256 supply = API3.totalSupply();
        require(supply < TARGET_SUPPLY, "ShutdownScript: supply already at the target");
        amounts.mint = TARGET_SUPPLY - supply;
        amounts.agentApi3 = API3.balanceOf(address(AGENT));
        amounts.secondaryUsdc = USDC.balanceOf(address(AGENT_SECONDARY));
        amounts.secondaryPnk = PNK.balanceOf(address(AGENT_SECONDARY));
        amounts.secondaryWpokt = WPOKT.balanceOf(address(AGENT_SECONDARY));
        amounts.secondaryEth = address(AGENT_SECONDARY).balance;
        require(amounts.agentApi3 > 0, "ShutdownScript: no API3 to move");
        require(amounts.secondaryUsdc > 0, "ShutdownScript: no USDC to move");
        require(amounts.secondaryPnk > 0, "ShutdownScript: no PNK to move");
        require(amounts.secondaryWpokt > 0, "ShutdownScript: no wPOKT to move");
        require(amounts.secondaryEth > 0, "ShutdownScript: no ETH to move");
    }

    /// The `metadata` argument of `newVote`, in the scheme the DAO dashboard decodes.
    function buildMetadata(string memory title, string memory description) internal pure returns (string memory) {
        return string.concat(METADATA_VERSION, METADATA_DELIMITER, title, METADATA_DELIMITER, description);
    }

    /// One CallsScript, following the rows of Appendix A in order. `_direct` entries are made by the primary voting
    /// app itself, `_viaAgent` entries by the primary Agent through `execute`. A NOTE marks every place the script
    /// differs from the appendix, and why.
    function buildScript(Amounts memory amounts) internal pure returns (bytes memory script) {
        script = abi.encodePacked(uint32(1));

        // 1. ACL, grantPermission(primary agent, secondary agent, TRANSFER_ROLE).
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.grantPermission, (address(AGENT), address(AGENT_SECONDARY), TRANSFER_ROLE))
            )
        );
        // NOTE: Not in the appendix. The ETH of row 2 cannot go through the secondary Agent's
        // `transfer`: Aragon's Vault sends ETH with `send`, and the 2300 gas stipend is not enough
        // for a Safe to receive it (`VAULT_SEND_REVERTED` on the fork, an EOA receives fine). The
        // ETH goes through `execute` instead, which needs EXECUTE_ROLE. The primary voting app
        // manages that role on the secondary Agent as well, so no other vote is needed.
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.grantPermission, (address(AGENT), address(AGENT_SECONDARY), EXECUTE_ROLE))
            )
        );

        // 2. Secondary agent, transfer to the agent multisig of its USDC, PNK, wPOKT and ETH.
        // NOTE: The appendix quotes balances read on 2 Sep 2026 and refreshed at posting. The amounts
        // are read from the chain when the script is built, which is what the refreshed figures
        // will be.
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(USDC), AGENT_SAFE, amounts.secondaryUsdc))
            )
        );
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(PNK), AGENT_SAFE, amounts.secondaryPnk))
            )
        );
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(WPOKT), AGENT_SAFE, amounts.secondaryWpokt))
            )
        );
        // NOTE: `execute` instead of `transfer` for the ETH, see row 1.
        script = bytes.concat(
            script,
            _viaAgent(address(AGENT_SECONDARY), abi.encodeCall(IAgent.execute, (AGENT_SAFE, amounts.secondaryEth, "")))
        );

        // 3. Primary agent, transfer to the vault of its API3. The primary voting app holds
        // TRANSFER_ROLE on the primary Agent, so this is a plain Agent transfer.
        script = bytes.concat(
            script, _direct(address(AGENT), abi.encodeCall(IAgent.transfer, (address(API3), VAULT, amounts.agentApi3)))
        );

        // 4 to 8. Api3Token calls, made by the primary Agent as the token owner.
        // 4. updateMinterStatus(Api3Pool, false). Rewards stop.
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(POOL), false)))
        );
        // 5. updateMinterStatus(primary agent, true).
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(AGENT), true)))
        );
        // 6. mint(vault, amount), the amount fixed when the script is built as 200,000,000 minus the
        // total supply at that block.
        script = bytes.concat(script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.mint, (VAULT, amounts.mint))));
        // 7. updateMinterStatus(primary agent, false).
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(AGENT), false)))
        );
        // 8. transferOwnership(dead).
        script = bytes.concat(script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.transferOwnership, (DEAD))));

        // 9. ACL, revokePermission(any address, CREATE_VOTES_ROLE) on both voting apps.
        script = bytes.concat(
            script,
            _direct(
                address(ACL), abi.encodeCall(IACL.revokePermission, (ANY_ENTITY, address(VOTING), CREATE_VOTES_ROLE))
            )
        );
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (ANY_ENTITY, address(VOTING_SECONDARY), CREATE_VOTES_ROLE))
            )
        );

        // 10. ACL, removePermissionManager(both voting apps, CREATE_VOTES_ROLE).
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), CREATE_VOTES_ROLE)))
        );
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), CREATE_VOTES_ROLE))
            )
        );

        // 11. Both voting apps, support and quorum to the contract maximum, then ACL,
        // removePermissionManager for MODIFY_SUPPORT_ROLE and MODIFY_QUORUM_ROLE on both. The
        // primary Agent holds the two modify roles. Support before quorum, as the appendix lists
        // it: the app rejects a quorum above the support.
        script = bytes.concat(
            script, _viaAgent(address(VOTING), abi.encodeCall(IApi3Voting.changeSupportRequiredPct, (MAX_PCT)))
        );
        script = bytes.concat(
            script, _viaAgent(address(VOTING), abi.encodeCall(IApi3Voting.changeMinAcceptQuorumPct, (MAX_PCT)))
        );
        script = bytes.concat(
            script,
            _viaAgent(address(VOTING_SECONDARY), abi.encodeCall(IApi3Voting.changeSupportRequiredPct, (MAX_PCT)))
        );
        script = bytes.concat(
            script,
            _viaAgent(address(VOTING_SECONDARY), abi.encodeCall(IApi3Voting.changeMinAcceptQuorumPct, (MAX_PCT)))
        );
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), MODIFY_SUPPORT_ROLE)))
        );
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), MODIFY_QUORUM_ROLE)))
        );
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), MODIFY_SUPPORT_ROLE))
            )
        );
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), MODIFY_QUORUM_ROLE))
            )
        );

        // 12. ACL, revoke the primary voting app's CREATE_PERMISSIONS_ROLE on the ACL and
        // APP_MANAGER_ROLE on the Kernel, and remove both managers.
        // NOTE: Not in the appendix. These are the DAO's root permissions, both held and managed
        // by the primary voting app. Removing a permission's manager, as rows 10 and 11 do, is
        // exactly what lets a holder of CREATE_PERMISSIONS_ROLE create that permission again, and
        // APP_MANAGER_ROLE swaps the code behind any app. Both were reachable only through a
        // primary vote, so rows 9 and 10 already put them out of reach. This row makes that hold
        // even for a vote created through a route not seen, or one still open at execution.
        // Revoke before removing the manager, and the ACL's own role last.
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (address(VOTING), address(KERNEL), APP_MANAGER_ROLE))
            )
        );
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(KERNEL), APP_MANAGER_ROLE)))
        );
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (address(VOTING), address(ACL), CREATE_PERMISSIONS_ROLE))
            )
        );
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(ACL), CREATE_PERMISSIONS_ROLE)))
        );
    }

    /// CallsScript entry made by the primary voting app itself: (target, calldata length, calldata).
    function _direct(address target, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(target, uint32(data.length), data);
    }

    /// CallsScript entry routed through the primary Agent, which owns the token and holds the
    /// permissions on the agents and the voting apps.
    function _viaAgent(address target, bytes memory data) internal pure returns (bytes memory) {
        return _direct(address(AGENT), abi.encodeCall(IAgent.execute, (target, 0, data)));
    }
}
