// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "./GovernorStorage.sol";

/// @title Governor
/// @author Forked from https://github.com/compound-finance/compound-protocol/tree/master/contracts/Governance
/// @notice Governance of Angle's protocol
contract Governor is GovernorStorage, AccessControlUpgradeable {
    /// @notice Name of this contract
    string public constant name = "Angle Governor";

    /// @notice Minimum setable proposal threshold
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 500_000e18; // 500,000 ANGLE

    /// @notice Maximum setable proposal threshold
    uint256 public constant MAX_PROPOSAL_THRESHOLD = 10_000_000e18; //10,000,000 ANGLE

    /// Attention all these parameters are to be modified before deployment, they should not be taken for truth
    /// @notice Minimum setable voting period
    uint256 public constant MIN_VOTING_PERIOD = 5; // About 2 min

    /// @notice Max setable voting period
    uint256 public constant MAX_VOTING_PERIOD = 80640; // About 2 weeks

    /// @notice Min setable voting delay
    uint256 public constant MIN_VOTING_DELAY = 5;

    /// @notice Max setable voting delay
    uint256 public constant MAX_VOTING_DELAY = 40320; // About 1 week

    /// @notice Number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    uint256 public constant quorumVotes = 40_000_000e18; // 400,000 = 4% of ANGLE

    /// @notice Maximum number of actions that can be included in a proposal
    uint256 public constant proposalMaxOperations = 10; // 10 actions

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,uint8 support)");

    // ============================ Constructor ===================================

    /// @notice Initializes the governance contract
    /// @param admin_ Admin of this contract
    /// @param timelock_ Address of the Timelock
    /// @param angle_ Address of the ANGLE token
    /// @param votingPeriod_ Initial voting period
    /// @param votingDelay_ Initial voting delay
    /// @param proposalThreshold_ Initial proposal threshold
    function initialize(
        address admin_,
        address timelock_,
        address angle_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 proposalThreshold_
    ) public initializer {
        require(timelock_ != address(0), "invalid timelock address");
        require(angle_ != address(0), "invalid ANGLE address");
        require(votingPeriod_ >= MIN_VOTING_PERIOD && votingPeriod_ <= MAX_VOTING_PERIOD, "invalid voting period");
        require(votingDelay_ >= MIN_VOTING_DELAY && votingDelay_ <= MAX_VOTING_DELAY, "invalid voting delay");
        require(
            proposalThreshold_ >= MIN_PROPOSAL_THRESHOLD && proposalThreshold_ <= MAX_PROPOSAL_THRESHOLD,
            "invalid proposal threshold"
        );

        adminAddress = admin_;
        timelock = ITimelock(timelock_);
        angle = ANGLEInterface(angle_);
        votingPeriod = votingPeriod_;
        votingDelay = votingDelay_;
        proposalThreshold = proposalThreshold_;

        timelock.acceptAdmin();
    }

    // ============================ Proposal and voting functions ===================================

    /// @notice Function used to propose a new proposal. Sender must have delegates above the proposal threshold
    /// @param targets Target addresses for proposal calls
    /// @param values Eth values for proposal calls
    /// @param signatures Function signatures for proposal calls
    /// @param calldatas Calldatas for proposal calls
    /// @param description String description of the proposal
    /// @return Proposal id of new proposal
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public returns (uint256) {
        // Reject proposals before initiating as Governor
        require(
            angle.getPriorVotes(msg.sender, block.number - 1) > proposalThreshold,
            "proposer votes below proposal threshold"
        );
        require(
            targets.length == values.length &&
                targets.length == signatures.length &&
                targets.length == calldatas.length,
            "proposal function information arity mismatch"
        );
        require(targets.length != 0, "must provide actions");
        require(targets.length <= proposalMaxOperations, "too many actions");

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(latestProposalId);
            require(
                proposersLatestProposalState != ProposalState.Active,
                "one live proposal per proposer, found an already active proposal"
            );
            require(
                proposersLatestProposalState != ProposalState.Pending,
                "one live proposal per proposer, found an already pending proposal"
            );
        }

        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;

        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.eta = 0;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.canceled = false;
        newProposal.executed = false;

        latestProposalIds[newProposal.proposer] = newProposal.id;

        emit ProposalCreated(
            newProposal.id,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
        return newProposal.id;
    }

    /// @notice Queues a proposal of state succeeded
    /// @param proposalId The id of the proposal to queue
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalState.Succeeded, "proposal can only be queued if it is succeeded");
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.timestamp + timelock.delay();
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    /// @notice Queues a given proposal
    /// @param target Target address for the proposal call
    /// @param value Eth value for the proposal calls
    /// @param signature Function signature for the proposal call
    /// @param data Calldata for the concerned proposal call
    /// @param eta Time at which the proposition will be considered
    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        require(
            !timelock.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta))),
            "identical proposal action already queued at eta"
        );
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    /// @notice Executes a queued proposal if eta has passed
    /// @param proposalId The id of the proposal to execute
    function execute(uint256 proposalId) external payable {
        require(state(proposalId) == ProposalState.Queued, "proposal can only be executed if it is queued");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.executeTransaction{ value: proposal.values[i] }(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice Cancels a proposal only if sender is the proposer, or proposer delegates dropped below proposal threshold
    /// @param proposalId The id of the proposal to cancel
    function cancel(uint256 proposalId) external {
        require(state(proposalId) != ProposalState.Executed, "cannot cancel executed proposal");

        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer ||
                angle.getPriorVotes(proposal.proposer, block.number - 1) < proposalThreshold,
            "proposer above threshold"
        );

        proposal.canceled = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.cancelTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }

        emit ProposalCanceled(proposalId);
    }

    /// @notice Gets actions of a proposal
    /// @param proposalId the id of the proposal
    function getActions(uint256 proposalId)
        external
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    /// @notice Gets the receipt for a voter on a given proposal
    /// @param proposalId the id of proposal
    /// @param voter The address of the voter
    /// @return The voting receipt
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }

    /// @notice Gets the state of a proposal
    /// @param proposalId The id of the proposal
    /// @return Proposal state
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalCount >= proposalId, "invalid proposal id");
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (block.timestamp >= proposal.eta + timelock.GRACE_PERIOD()) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /// @notice Casts a vote for a proposal
    /// @param proposalId The id of the proposal to vote on
    /// @param support The support value for the vote. 0=against, 1=for, 2=abstain
    function castVote(uint256 proposalId, uint8 support) external {
        emit VoteCast(msg.sender, proposalId, support, _castVote(msg.sender, proposalId, support), "");
    }

    /// @notice Casts a vote for a proposal with a reason
    /// @param proposalId The id of the proposal to vote on
    /// @param support The support value for the vote. 0=against, 1=for, 2=abstain
    /// @param reason The reason given for the vote by the voter
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external {
        emit VoteCast(msg.sender, proposalId, support, _castVote(msg.sender, proposalId, support), reason);
    }

    /// @notice Casts a vote for a proposal by signature
    /// @dev External function that accepts EIP-712 signatures for voting on proposals.
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), _getChainIdInternal(), address(this))
        );
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "invalid signature");
        emit VoteCast(signatory, proposalId, support, _castVote(signatory, proposalId, support), "");
    }

    /// @notice Internal function that caries out voting logic
    /// @param voter The voter that is casting their vote
    /// @param proposalId The id of the proposal to vote on
    /// @param support The support value for the vote. 0=against, 1=for, 2=abstain
    /// @return The number of votes cast
    function _castVote(
        address voter,
        uint256 proposalId,
        uint8 support
    ) internal returns (uint96) {
        require(state(proposalId) == ProposalState.Active, "voting is closed");
        require(support <= 2, "invalid vote type");
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(receipt.hasVoted == false, "voter already voted");
        uint96 votes = angle.getPriorVotes(voter, proposal.startBlock);

        if (support == 0) {
            proposal.againstVotes = proposal.againstVotes + votes;
        } else if (support == 1) {
            proposal.forVotes = proposal.forVotes + votes;
        } else if (support == 2) {
            proposal.abstainVotes = proposal.abstainVotes + votes;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        return votes;
    }

    // ============================ Governance ===================================

    /// @notice Admin function for setting the voting delay
    /// @param newVotingDelay New voting delay, in blocks
    function setVotingDelay(uint256 newVotingDelay) external {
        require(msg.sender == adminAddress, "admin only");
        require(newVotingDelay >= MIN_VOTING_DELAY && newVotingDelay <= MAX_VOTING_DELAY, "invalid voting delay");
        uint256 oldVotingDelay = votingDelay;
        votingDelay = newVotingDelay;

        emit VotingDelaySet(oldVotingDelay, votingDelay);
    }

    /// @notice Admin function for setting the voting period
    /// @param newVotingPeriod New voting period, in blocks
    function setVotingPeriod(uint256 newVotingPeriod) external {
        require(msg.sender == adminAddress, "admin only");
        require(newVotingPeriod >= MIN_VOTING_PERIOD && newVotingPeriod <= MAX_VOTING_PERIOD, "invalid voting period");
        uint256 oldVotingPeriod = votingPeriod;
        votingPeriod = newVotingPeriod;

        emit VotingPeriodSet(oldVotingPeriod, votingPeriod);
    }

    /// @notice Admin function for setting the proposal threshold
    /// @param newProposalThreshold New proposal threshold
    /// @dev newProposalThreshold Must be greater than the hardcoded min
    function setProposalThreshold(uint256 newProposalThreshold) external {
        require(msg.sender == adminAddress, "admin only");
        require(
            newProposalThreshold >= MIN_PROPOSAL_THRESHOLD && newProposalThreshold <= MAX_PROPOSAL_THRESHOLD,
            "invalid proposal threshold"
        );
        uint256 oldProposalThreshold = proposalThreshold;
        proposalThreshold = newProposalThreshold;

        emit ProposalThresholdSet(oldProposalThreshold, proposalThreshold);
    }

    /// @notice Begins transfer of admin rights. The newPendingAdmin must call `acceptAdmin` to finalize the transfer.
    /// @dev Admin function to begin change of admin. The newPendingAdmin must call `acceptAdmin` to finalize the transfer.
    /// @param newPendingAdmin New pending admin.
    function setPendingAdmin(address newPendingAdmin) external {
        // Check caller = admin
        require(msg.sender == adminAddress, "admin only");
        require(newPendingAdmin != address(0), "zero address");

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
    /// @dev Admin function for pending admin to accept role and update admin
    function acceptAdmin() external {
        // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
        require(msg.sender == pendingAdmin && msg.sender != address(0), "pending admin only");

        // Save current values for inclusion in log
        address oldAdmin = adminAddress;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        adminAddress = pendingAdmin;

        // Clear the pending value
        pendingAdmin = address(0);

        emit NewAdmin(oldAdmin, adminAddress);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);
    }

    // ============================ Internal ===================================

    function _getChainIdInternal() internal view returns (uint256) {
        uint256 chainId;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}
