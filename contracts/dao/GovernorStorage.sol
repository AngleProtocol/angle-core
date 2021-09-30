// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "./GovernorEvents.sol";

/// @title GovernorStorage
/// @author Forked from https://github.com/compound-finance/compound-protocol/tree/master/contracts/Governance
/// @notice Storage for Governor
/// @dev For future upgrades, do not change GovernorStorage. Create a new
/// contract which implements GovernorStorage and following the naming convention
/// GovernorStorageVX.
abstract contract GovernorStorage is GovernorEvents {
    /// @notice Administrator for this contract
    address public adminAddress;

    /// @notice Pending administrator for this contract
    address public pendingAdmin;

    /// @notice Delay before voting on a proposal may take place, once proposed, in blocks
    uint256 public votingDelay;

    /// @notice Duration of voting on a proposal, in blocks
    uint256 public votingPeriod;

    /// @notice Number of votes required in order for a voter to become a proposer
    uint256 public proposalThreshold;

    /// @notice Total number of proposals
    uint256 public proposalCount;

    /// @notice Address of the Angle Protocol's Timelock
    ITimelock public timelock;

    /// @notice Address of the Angle governance token
    ANGLEInterface public angle;

    /// @notice Official record of all proposals ever proposed
    mapping(uint256 => Proposal) public proposals;

    /// @notice Latest proposal for each proposer
    mapping(address => uint256) public latestProposalIds;

    struct Proposal {
        // Unique id for looking up a proposal
        uint256 id;
        // Creator of the proposal
        address proposer;
        // The timestamp that the proposal will be available for execution, set once the vote succeeds
        uint256 eta;
        // the ordered list of target addresses for calls to be made
        address[] targets;
        // The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint256[] values;
        // The ordered list of function signatures to be called
        string[] signatures;
        // The ordered list of calldata to be passed to each call
        bytes[] calldatas;
        // The block at which voting begins: holders must delegate their votes prior to this block
        uint256 startBlock;
        // The block at which voting ends: votes must be cast prior to this block
        uint256 endBlock;
        // Current number of votes in favor of this proposal
        uint256 forVotes;
        // Current number of votes in opposition to this proposal
        uint256 againstVotes;
        // Current number of votes for abstaining for this proposal
        uint256 abstainVotes;
        // Flag marking whether the proposal has been canceled
        bool canceled;
        // Flag marking whether the proposal has been executed
        bool executed;
        // Receipts of ballots for the entire set of voters
        mapping(address => Receipt) receipts;
    }

    /// @notice Ballot receipt record for a voter
    struct Receipt {
        // Whether or not a vote has been cast
        bool hasVoted;
        // Whether or not the voter supports the proposal or abstains
        uint8 support;
        // The number of votes the voter had, which were cast
        uint96 votes;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
}
