// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Executed_Test} from "../Base.t.sol";

/// The legacy voting apps after the migration: no new votes, settings and permissions final.
contract Dao_Aragon_Test is Executed_Test {
    function test_WhenAnyoneTriesToCreateAVoteOnEitherApp() external {
        // it should revert with APP_AUTH_FAILED.
        vm.prank(_proposer());
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        VOTING.newVote(hex"00000001", "after the migration", true, false);
        vm.prank(_proposer());
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        VOTING_SECONDARY.newVote(hex"00000001", "after the migration", true, false);
    }

    function test_ShouldLeaveVoteCreationOnBothAppsWithoutAPermissionManager() external view {
        // it should leave vote creation on both apps without a permission manager.
        assertEq(
            ACL.getPermissionManager(address(VOTING), CREATE_VOTES_ROLE),
            address(0),
            "primary vote creation has no manager"
        );
        assertEq(
            ACL.getPermissionManager(address(VOTING_SECONDARY), CREATE_VOTES_ROLE),
            address(0),
            "secondary vote creation has no manager"
        );
    }

    function test_ShouldHoldSupportAndQuorumAtTheMaximumOnBothAppsWithNoManagerLeft() external view {
        // it should hold support and quorum at the maximum on both apps with no manager left.
        assertEq(VOTING.supportRequiredPct(), MAX_PCT);
        assertEq(VOTING.minAcceptQuorumPct(), MAX_PCT);
        assertEq(VOTING_SECONDARY.supportRequiredPct(), MAX_PCT);
        assertEq(VOTING_SECONDARY.minAcceptQuorumPct(), MAX_PCT);
        assertEq(ACL.getPermissionManager(address(VOTING), MODIFY_SUPPORT_ROLE), address(0));
        assertEq(ACL.getPermissionManager(address(VOTING), MODIFY_QUORUM_ROLE), address(0));
        assertEq(ACL.getPermissionManager(address(VOTING_SECONDARY), MODIFY_SUPPORT_ROLE), address(0));
        assertEq(ACL.getPermissionManager(address(VOTING_SECONDARY), MODIFY_QUORUM_ROLE), address(0));
    }

    function test_ShouldTakeTheACLAndKernelRootPermissionsFromThePrimaryVotingAppAndLeaveThemWithoutAManager()
        external
        view
    {
        // it should take the ACL and Kernel root permissions from the primary voting app and leave them without a manager.
        assertFalse(ACL.hasPermission(address(VOTING), address(ACL), CREATE_PERMISSIONS_ROLE), "no permission creator");
        assertEq(
            ACL.getPermissionManager(address(ACL), CREATE_PERMISSIONS_ROLE),
            address(0),
            "permission creation has no manager"
        );
        assertFalse(ACL.hasPermission(address(VOTING), address(KERNEL), APP_MANAGER_ROLE), "no app manager");
        assertEq(
            ACL.getPermissionManager(address(KERNEL), APP_MANAGER_ROLE), address(0), "app management has no manager"
        );
    }

    function test_WhenThePrimaryVotingAppItselfTriesToCreateAPermissionOrSwapAnAppsCode() external {
        // it should revert with APP_AUTH_FAILED and KERNEL_AUTH_FAILED.
        // The primary voting app was the only holder of both roles, so a vote that somehow executes is the strongest
        // caller there is. Vote creation has no manager, the state createPermission needs, and it still fails.
        vm.startPrank(address(VOTING));
        vm.expectRevert(bytes("APP_AUTH_FAILED"));
        ACL.createPermission(VAULT, address(VOTING), CREATE_VOTES_ROLE, VAULT);
        bytes32 votingAppId = keccak256("api3voting");
        vm.expectRevert(bytes("KERNEL_AUTH_FAILED"));
        KERNEL.setApp(APP_BASES_NAMESPACE, votingAppId, address(POOL));
        vm.stopPrank();
    }
}
