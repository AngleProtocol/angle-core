// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorProposalThresholdUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Governor is
    Initializable,
    GovernorUpgradeable,
    GovernorProposalThresholdUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable
{
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event VotingDelayUpdated(uint256 oldVotingDelay, uint256 newVotingDelay);
    event VotingPeriodUpdated(uint256 oldVotingPeriod, uint256 newVotingPeriod);
    event ProposalThresholdUpdated(uint256 oldProposalThreshold, uint256 newProposalThreshold);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    uint256 private _votingDelay;
    uint256 private _votingPeriod;
    uint256 private _quorum;
    uint256 private _proposalThreshold;

    function initialize(ERC20VotesUpgradeable _token, TimelockControllerUpgradeable _timelock) public initializer {
        __Governor_init("Angle Governor");
        __GovernorProposalThreshold_init();
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorTimelockControl_init(_timelock);

        _votingDelay = 545; // 2 hours
        _votingPeriod = 19636; // 3 day
        _quorum = 25_000_000e18; // 25M ANGLE
        _proposalThreshold = 2500_000e18; // 2M5 ANGLE
    }

    /// @notice Returns the voting delay
    function votingDelay() public view override returns (uint256) {
        return _votingDelay;
    }

    /// @notice Returns the voting period
    function votingPeriod() public view override returns (uint256) {
        return _votingPeriod;
    }

    /// @notice Returns the quorum
    function quorum(uint256 blockNumber) public view override returns (uint256) {
        require(blockNumber < block.number, "ERC20Votes: block not yet mined");
        return _quorum;
    }

    /// @notice Returns the proposal threshold
    function proposalThreshold() public view override returns (uint256) {
        return _proposalThreshold;
    }

    /// @notice Sets the voting delay
    /// @param newVotingDelay New voting delay
    function setVotingDelay(uint256 newVotingDelay) public onlyGovernance {
        uint256 oldVotingDelay = _votingDelay;
        _votingDelay = newVotingDelay;
        emit VotingDelayUpdated(oldVotingDelay, newVotingDelay);
    }

    /// @notice Sets the voting period
    /// @param newVotingPeriod New voting period
    function setVotingPeriod(uint256 newVotingPeriod) public onlyGovernance {
        uint256 oldVotingPeriod = _votingPeriod;
        _votingPeriod = newVotingPeriod;
        emit VotingPeriodUpdated(oldVotingPeriod, newVotingPeriod);
    }

    /// @notice Sets the quorum
    /// @param newQuorum New quorum
    function setQuorum(uint256 newQuorum) public onlyGovernance {
        uint256 oldQuorum = _quorum;
        _quorum = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    /// @notice Sets the proposal threshold
    /// @param newProposalThreshold Proposal threshold
    function setProposalThreshold(uint256 newProposalThreshold) public onlyGovernance {
        uint256 oldProposalThreshold = _proposalThreshold;
        _proposalThreshold = newProposalThreshold;
        emit ProposalThresholdUpdated(oldProposalThreshold, newProposalThreshold);
    }

    // The following functions are overrides required by Solidity.

    function getVotes(address account, uint256 blockNumber)
        public
        view
        override(IGovernorUpgradeable, GovernorVotesUpgradeable)
        returns (uint256)
    {
        return super.getVotes(account, blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        override(GovernorUpgradeable, GovernorProposalThresholdUpgradeable, IGovernorUpgradeable)
        returns (uint256)
    {
        return super.propose(targets, values, calldatas, description);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
