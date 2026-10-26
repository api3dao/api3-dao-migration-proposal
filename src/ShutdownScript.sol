// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "./Interfaces.sol";

/// @notice The vote script of the primary proposal that winds down the legacy DAO, built the same way for the fork
/// tests and for the vote that gets posted. The calls are the ones the proposal text lists, in its order, one Aragon
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
    /// Posts the vote. It stakes nothing but holds the pool shares delegated to it, which clear the proposal
    /// threshold, and it votes on Snapshot with that delegated stake, which is why the API3 does not go to it.
    address constant VAULT = 0x8e03609ed680B237C7b6f8020472CA0687308b24;
    /// Receives the API3 the vote moves, the mint and the primary Agent's balance. A Safe with the same five signers
    /// as the Vault and Agent Safes that only holds: its Snapshot voting power is delegated to the dead address, so the
    /// treasury's weight stays apart from the Vault's delegated power. `CreateVote.s.sol` and the file and posted-vote
    /// test modes check that the address has code.
    address constant TREASURY_SAFE = 0xb7fa2Cb302C5dC127e61F27b92beC411cbf0AE4A;
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
        /// Minted into the Treasury Safe, 200,000,000 API3 minus the total supply at that block.
        uint256 mint;
        /// The primary Agent's API3, moved to the Treasury Safe.
        uint256 agentApi3;
        /// The secondary Agent's balances, moved to the agent multisig.
        uint256 secondaryUsdc;
        uint256 secondaryPnk;
        uint256 secondaryWpokt;
        uint256 secondaryEth;
    }

    /// Every amount has to be positive. Aragon's Vault refuses a zero transfer, and one reverting call reverts the
    /// whole script, so a call with nothing to move has to be dropped from the script rather than left in with a zero.
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

    /// One CallsScript of 28 calls, in the order the proposal text lists them. `_direct` entries are made by the
    /// primary voting app itself, `_viaAgent` entries by the primary Agent through `execute`. The comments give the
    /// reason behind a call where there is one.
    function buildScript(Amounts memory amounts) internal pure returns (bytes memory script) {
        script = abi.encodePacked(uint32(1));

        // Calls 1 and 2: the ACL grants the primary Agent TRANSFER_ROLE and EXECUTE_ROLE on the secondary
        // Agent. EXECUTE_ROLE because the ETH of call 6 cannot leave through the secondary Agent's `transfer`:
        // Aragon's Vault sends ETH with `send`, and the 2300 gas stipend is not enough for a Safe to receive it
        // (`VAULT_SEND_REVERTED` on the fork, an EOA receives fine). The ETH goes through `execute` instead, which
        // needs EXECUTE_ROLE. The primary voting app manages that role on the secondary Agent as well, so no other
        // vote is needed.
        // Call 1
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.grantPermission, (address(AGENT), address(AGENT_SECONDARY), TRANSFER_ROLE))
            )
        );
        // Call 2
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.grantPermission, (address(AGENT), address(AGENT_SECONDARY), EXECUTE_ROLE))
            )
        );

        // Calls 3 to 6: the secondary Agent transfers its USDC, PNK, wPOKT and ETH to the agent multisig. The
        // amounts are read from the chain when the script is built, right before posting. The proposal text quotes
        // the balances of an earlier day and points here for the posted ones.
        // Call 3, USDC
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(USDC), AGENT_SAFE, amounts.secondaryUsdc))
            )
        );
        // Call 4, PNK
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(PNK), AGENT_SAFE, amounts.secondaryPnk))
            )
        );
        // Call 5, wPOKT
        script = bytes.concat(
            script,
            _viaAgent(
                address(AGENT_SECONDARY),
                abi.encodeCall(IAgent.transfer, (address(WPOKT), AGENT_SAFE, amounts.secondaryWpokt))
            )
        );
        // Call 6, ETH, through `execute` instead of `transfer`, see calls 1 and 2
        script = bytes.concat(
            script,
            _viaAgent(address(AGENT_SECONDARY), abi.encodeCall(IAgent.execute, (AGENT_SAFE, amounts.secondaryEth, "")))
        );

        // Call 7: the primary Agent transfers its API3 to the Treasury Safe. The primary voting app holds
        // TRANSFER_ROLE on the primary Agent, so this is a plain Agent transfer, not one through `execute`. The
        // Treasury Safe rather than the Vault: the Vault votes on Snapshot with the pool stake delegated to it, so
        // the API3 goes to a Safe that never votes.
        script = bytes.concat(
            script,
            _direct(address(AGENT), abi.encodeCall(IAgent.transfer, (address(API3), TREASURY_SAFE, amounts.agentApi3)))
        );

        // Calls 8 to 12: Api3Token calls, made by the primary Agent as the token owner.
        // Call 8: updateMinterStatus(Api3Pool, false). Rewards stop.
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(POOL), false)))
        );
        // Call 9: updateMinterStatus(primary Agent, true).
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(AGENT), true)))
        );
        // Call 10: mint(Treasury Safe, amount), the amount fixed when the script is built as 200,000,000
        // minus the total supply at that block. The Treasury Safe for the reason given at call 7. If the pool mints once
        // more before execution, the Treasury Safe burns the excess afterwards.
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.mint, (TREASURY_SAFE, amounts.mint)))
        );
        // Call 11: updateMinterStatus(primary Agent, false).
        script = bytes.concat(
            script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.updateMinterStatus, (address(AGENT), false)))
        );
        // Call 12: transferOwnership(dead). `renounceOwnership` reverts by design, so this is the only way to
        // freeze the minter set.
        script = bytes.concat(script, _viaAgent(address(API3), abi.encodeCall(IApi3Token.transferOwnership, (DEAD))));

        // Calls 13 and 14: the ACL revokes CREATE_VOTES_ROLE from any address on both voting apps.
        // Call 13, primary voting app
        script = bytes.concat(
            script,
            _direct(
                address(ACL), abi.encodeCall(IACL.revokePermission, (ANY_ENTITY, address(VOTING), CREATE_VOTES_ROLE))
            )
        );
        // Call 14, secondary voting app
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (ANY_ENTITY, address(VOTING_SECONDARY), CREATE_VOTES_ROLE))
            )
        );

        // Calls 15 and 16: the ACL removes the manager of CREATE_VOTES_ROLE on both voting apps, so nobody
        // can grant it again.
        // Call 15, primary voting app
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), CREATE_VOTES_ROLE)))
        );
        // Call 16, secondary voting app
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), CREATE_VOTES_ROLE))
            )
        );

        // Calls 17 to 24: both voting apps raise support and quorum to the contract maximum, then the ACL
        // removes the managers of MODIFY_SUPPORT_ROLE and MODIFY_QUORUM_ROLE on both. The primary Agent holds the
        // two modify roles. Support before quorum: the app rejects a quorum above the support.
        // Call 17, primary voting app support
        script = bytes.concat(
            script, _viaAgent(address(VOTING), abi.encodeCall(IApi3Voting.changeSupportRequiredPct, (MAX_PCT)))
        );
        // Call 18, primary voting app quorum
        script = bytes.concat(
            script, _viaAgent(address(VOTING), abi.encodeCall(IApi3Voting.changeMinAcceptQuorumPct, (MAX_PCT)))
        );
        // Call 19, secondary voting app support
        script = bytes.concat(
            script,
            _viaAgent(address(VOTING_SECONDARY), abi.encodeCall(IApi3Voting.changeSupportRequiredPct, (MAX_PCT)))
        );
        // Call 20, secondary voting app quorum
        script = bytes.concat(
            script,
            _viaAgent(address(VOTING_SECONDARY), abi.encodeCall(IApi3Voting.changeMinAcceptQuorumPct, (MAX_PCT)))
        );
        // Call 21, primary voting app MODIFY_SUPPORT_ROLE manager
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), MODIFY_SUPPORT_ROLE)))
        );
        // Call 22, primary voting app MODIFY_QUORUM_ROLE manager
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(VOTING), MODIFY_QUORUM_ROLE)))
        );
        // Call 23, secondary voting app MODIFY_SUPPORT_ROLE manager
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), MODIFY_SUPPORT_ROLE))
            )
        );
        // Call 24, secondary voting app MODIFY_QUORUM_ROLE manager
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.removePermissionManager, (address(VOTING_SECONDARY), MODIFY_QUORUM_ROLE))
            )
        );

        // Calls 25 to 28: the ACL revokes the primary voting app's APP_MANAGER_ROLE on the Kernel and
        // CREATE_PERMISSIONS_ROLE on the ACL, and removes both managers. These are the DAO's root permissions, both
        // held and managed by the primary voting app. Removing a permission's manager, as calls 15, 16 and 21 to 24 do,
        // is exactly what lets a holder of CREATE_PERMISSIONS_ROLE create that permission again, and APP_MANAGER_ROLE
        // swaps the code behind any app. Both were reachable only through a primary vote, so calls 13 to 16 already
        // put them out of reach. These calls make that hold even for a vote created through a route not seen, or one
        // still open at execution. Revoke before removing the manager, and the ACL's own role last.
        // Call 25, revoke APP_MANAGER_ROLE on the Kernel
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (address(VOTING), address(KERNEL), APP_MANAGER_ROLE))
            )
        );
        // Call 26, remove its manager
        script = bytes.concat(
            script,
            _direct(address(ACL), abi.encodeCall(IACL.removePermissionManager, (address(KERNEL), APP_MANAGER_ROLE)))
        );
        // Call 27, revoke CREATE_PERMISSIONS_ROLE on the ACL
        script = bytes.concat(
            script,
            _direct(
                address(ACL),
                abi.encodeCall(IACL.revokePermission, (address(VOTING), address(ACL), CREATE_PERMISSIONS_ROLE))
            )
        );
        // Call 28, remove its manager
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
