// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface IApi3Voting {
    function newVote(bytes calldata script, string calldata metadata, bool castVote, bool executesIfDecided)
        external
        returns (uint256);
    function vote(uint256 voteId, bool inFavor, bool executesIfDecided) external;
    function executeVote(uint256 voteId) external;
    function canExecute(uint256 voteId) external view returns (bool);
    function votesLength() external view returns (uint256);
    function voteTime() external view returns (uint64);
    function supportRequiredPct() external view returns (uint64);
    function minAcceptQuorumPct() external view returns (uint64);
    function changeSupportRequiredPct(uint64 pct) external;
    function changeMinAcceptQuorumPct(uint64 pct) external;
    function getVote(uint256 voteId)
        external
        view
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 yea,
            uint256 nay,
            uint256 votingPower,
            bytes memory script
        );
}

interface IAgent {
    function execute(address target, uint256 ethValue, bytes calldata data) external;
    function transfer(address token, address to, uint256 value) external;
}

interface IACL {
    function createPermission(address entity, address app, bytes32 role, address manager) external;
    function grantPermission(address entity, address app, bytes32 role) external;
    function revokePermission(address entity, address app, bytes32 role) external;
    function removePermissionManager(address app, bytes32 role) external;
    function getPermissionManager(address app, bytes32 role) external view returns (address);
    function hasPermission(address who, address where, bytes32 what) external view returns (bool);
}

interface IKernel {
    function setApp(bytes32 namespace, bytes32 appId, address app) external;
    function getApp(bytes32 namespace, bytes32 appId) external view returns (address);
}

interface IApi3Token {
    function owner() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function getMinterStatus(address) external view returns (bool);
    function updateMinterStatus(address, bool) external;
    function mint(address, uint256) external;
    function transferOwnership(address) external;
    function updateBurnerStatus(bool) external;
    function getBurnerStatus(address) external view returns (bool);
    function burn(uint256) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IApi3Pool {
    function mintReward() external;
    function depositAndStake(uint256) external;
    function depositRegular(uint256) external;
    function stake(uint256) external;
    function scheduleUnstake(uint256 amount) external;
    function unstake(address user) external returns (uint256);
    function withdrawRegular(uint256 amount) external;
    function totalStake() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function proposalVotingPowerThreshold() external view returns (uint256);
    function userVotingPower(address) external view returns (uint256);
    function userVotingPowerAt(address, uint256) external view returns (uint256);
    function userStake(address) external view returns (uint256);
    function userLocked(address) external view returns (uint256);
    function epochIndexOfLastReward() external view returns (uint256);
    function setClaimsManagerStatus(address claimsManager, bool status) external;
    function claimsManagerStatus(address) external view returns (bool);
    function payOutClaim(address recipient, uint256 amount) external;
    function getUser(address)
        external
        view
        returns (
            uint256 unstaked,
            uint256 vesting,
            uint256 unstakeAmount,
            uint256 unstakeShares,
            uint256 unstakeScheduledFor,
            uint256 lastDelegationUpdateTimestamp,
            uint256 lastProposalTimestamp
        );
}
