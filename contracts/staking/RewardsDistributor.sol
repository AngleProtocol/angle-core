// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./RewardsDistributorEvents.sol";

/// @title RewardsDistributor
/// @author Angle Core Team (forked form FEI Protocol)
/// @notice Controls and handles the distribution of governance tokens to the different staking contracts of the protocol
/// @dev Inspired from FEI contract:
/// https://github.com/fei-protocol/fei-protocol-core/blob/master/contracts/staking/FeiRewardsDistributor.sol
contract RewardsDistributor is RewardsDistributorEvents, IRewardsDistributor, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Distribution parameters for a given contract
    struct StakingParameters {
        // Amount of rewards distributed since the beginning
        uint256 distributedRewards;
        // Last time rewards were distributed to the staking contract
        uint256 lastDistributionTime;
        // Frequency with which rewards should be given to the underlying contract
        uint256 updateFrequency;
        // Number of tokens distributed for the person calling the update function
        uint256 incentiveAmount;
        // Time at which reward distribution started for this reward contract
        uint256 timeStarted;
        // Duration during which rewards will be distributed
        uint256 duration;
        // Amount of tokens to distribute to the concerned contract
        uint256 amountToDistribute;
    }

    // ============================ Reference to a contract ========================

    /// @notice Token used as a reward
    IERC20 public override rewardToken;

    // ============================== Parameters ===================================

    /// @notice Maps a `StakingContract` to its distribution parameters
    mapping(IStakingRewards => StakingParameters) public stakingContractsMap;

    /// @notice List of all the staking contracts handled by the rewards distributor
    /// Used to be able to change the rewards distributor and propagate a new reference to the underlying
    /// staking contract
    IStakingRewards[] public stakingContractsList;

    // ============================ Constructor ====================================

    /// @notice Initializes the distributor contract with a first set of parameters
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian The guardian address, optional
    /// @param rewardTokenAddress The ERC20 token to distribute
    constructor(
        address[] memory governorList,
        address guardian,
        address rewardTokenAddress
    ) {
        require(rewardTokenAddress != address(0) && guardian != address(0), "zero address");
        rewardToken = IERC20(rewardTokenAddress);
        // Since this contract is independent from the rest of the protocol
        // When updating the governor list, governors should make sure to still update the roles
        // in this contract
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "zero address");
            _setupRole(GOVERNOR_ROLE, governorList[i]);
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }
        _setupRole(GUARDIAN_ROLE, guardian);
    }

    // ============================ External Functions =============================

    /// @notice Sends governance token to the staking contract
    /// @param stakingContract Reference to the staking contract
    /// @dev The way to pause this function is to set `updateFrequency` to infinity,
    /// or to completely delete the contract
    /// @dev A keeper calling this function could be frontran by a miner seeing the potential profit
    /// from calling this function
    function drip(IStakingRewards stakingContract) external override returns (uint256) {
        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];
        require(stakingParams.duration > 0, "invalid staking contract");
        require(_isDripAvailable(stakingParams), "not passed drip frequency");

        stakingParams.lastDistributionTime = block.timestamp;

        uint256 dripAmount = _computeDripAmount(stakingParams);
        require(dripAmount != 0, "no rewards");
        stakingParams.distributedRewards = stakingParams.distributedRewards + dripAmount;
        emit Dripped(msg.sender, dripAmount, address(stakingContract));

        rewardToken.safeTransfer(address(stakingContract), dripAmount);
        IStakingRewards(stakingContract).notifyRewardAmount(dripAmount);
        _incentivize(stakingParams);

        return dripAmount;
    }

    // =========================== Governor Functions ==============================

    /// @notice Sends tokens back to governance treasury or another address
    /// @param amount Amount of tokens to send back to treasury
    /// @param to Address to send the tokens to
    /// @dev Only callable by governance and not by the guardian
    function governorWithdrawRewardToken(uint256 amount, address to) external override onlyRole(GOVERNOR_ROLE) {
        emit ANGLEWithdrawn(amount);
        rewardToken.safeTransfer(to, amount);
    }

    /// @notice Function to withdraw ERC20 tokens that could accrue on a staking contract
    /// @param tokenAddress Address of the ERC20 to recover
    /// @param to Address to transfer to
    /// @param amount Amount to transfer
    /// @param stakingContract Reference to the staking contract
    /// @dev A use case would be to claim tokens if the staked tokens accumulate rewards
    function governorRecover(
        address tokenAddress,
        address to,
        uint256 amount,
        IStakingRewards stakingContract
    ) external override onlyRole(GOVERNOR_ROLE) {
        stakingContract.recoverERC20(tokenAddress, to, amount);
    }

    /// @notice Sets a new rewards distributor contract and automatically makes this contract useless
    /// @param newRewardsDistributor Address of the new rewards distributor contract
    /// @dev This contract is not upgradable, setting a new contract could allow for upgrades, which should be
    /// propagated across all staking contracts
    /// @dev This function transfers all the reward tokens to the new address
    /// @dev The new rewards distributor contract should be initialized correctly with all the staking contracts
    /// from the staking contract list
    function setNewRewardsDistributor(address newRewardsDistributor) external override onlyRole(GOVERNOR_ROLE) {
        require(newRewardsDistributor != address(0), "zero address");
        for (uint256 i = 0; i < stakingContractsList.length; i++) {
            stakingContractsList[i].setNewRewardsDistributor(newRewardsDistributor);
        }
        rewardToken.safeTransfer(newRewardsDistributor, rewardToken.balanceOf(address(this)));
        // The functions `setStakingContract` should then be called for each staking contract in the `newRewardsDistributor`
        emit NewRewardsDistributor(newRewardsDistributor);
    }

    /// @notice Deletes a staking contract from the staking contract map and removes it from the
    /// `stakingContractsList`
    /// @param stakingContract Contract to remove
    /// @dev Allows to clean some space and to avoid keeping in memory contracts which became useless
    /// @dev It is also a way governance has to completely stop rewards distribution from a contract
    function removeStakingContract(IStakingRewards stakingContract) external override onlyRole(GOVERNOR_ROLE) {
        uint256 indexMet = 0;
        for (uint256 i = 0; i < stakingContractsList.length - 1; i++) {
            if (address(stakingContractsList[i]) == address(stakingContract)) {
                indexMet = 1;
            }
            if (indexMet == 1) {
                stakingContractsList[i] = stakingContractsList[i + 1];
            }
        }
        require(
            indexMet == 1 || stakingContractsList[stakingContractsList.length - 1] == stakingContract,
            "incorrect staking contract"
        );

        stakingContractsList.pop();

        delete stakingContractsMap[stakingContract];
        emit DeletedStakingContract(address(stakingContract));
    }

    // =================== Guardian Functions (for parameters) =====================

    /// @notice Notifies and initializes a new staking contract
    /// @param _stakingContract Address of the staking contract
    /// @param _duration Time frame during which tokens will be distributed
    /// @param _incentiveAmount Incentive amount given to keepers calling the update function
    /// @param _updateFrequency Frequency when it is possible to call the update function and give tokens to the staking contract
    /// @param _amountToDistribute Amount of gov tokens to give to the staking contract across all drips
    /// @dev Called by governance to activate a contract
    function setStakingContract(
        address _stakingContract,
        uint256 _duration,
        uint256 _incentiveAmount,
        uint256 _updateFrequency,
        uint256 _amountToDistribute
    ) external override onlyRole(GUARDIAN_ROLE) {
        require(_duration > 0, "null duration");
        require(_duration >= _updateFrequency, "frequency exceeds duration");

        IStakingRewards stakingContract = IStakingRewards(_stakingContract);

        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];

        stakingParams.updateFrequency = _updateFrequency;
        stakingParams.incentiveAmount = _incentiveAmount;
        stakingParams.lastDistributionTime = block.timestamp;
        stakingParams.timeStarted = block.timestamp;
        stakingParams.duration = _duration;

        stakingParams.amountToDistribute = _amountToDistribute;

        stakingContractsList.push(stakingContract);

        emit NewStakingContract(_stakingContract);
    }

    /// @notice Sets the update frequency
    /// @param _updateFrequency New update frequency
    /// @param stakingContract Reference to the staking contract
    function setUpdateFrequency(uint256 _updateFrequency, IStakingRewards stakingContract)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];
        require(stakingParams.duration > 0, "invalid staking contract");
        stakingParams.updateFrequency = _updateFrequency;
        emit FrequencyUpdated(_updateFrequency, address(stakingContract));
    }

    /// @notice Sets the incentive amount for calling drip
    /// @param _incentiveAmount New incentive amount
    /// @param stakingContract Reference to the staking contract
    function setIncentiveAmount(uint256 _incentiveAmount, IStakingRewards stakingContract)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];
        require(stakingParams.duration > 0, "invalid staking contract");
        stakingParams.incentiveAmount = _incentiveAmount;
        emit IncentiveUpdated(_incentiveAmount, address(stakingContract));
    }

    /// @notice Sets the new amount to distribute to a staking contract
    /// @param _amountToDistribute New amount to distribute
    /// @param stakingContract Reference to the staking contract
    function setAmountToDistribute(uint256 _amountToDistribute, IStakingRewards stakingContract)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];
        require(stakingParams.duration > 0, "invalid staking contract");
        require(stakingParams.distributedRewards < _amountToDistribute, "invalid amount to distribute");
        stakingParams.amountToDistribute = _amountToDistribute;
        emit AmountToDistributeUpdated(_amountToDistribute, address(stakingContract));
    }

    /// @notice Sets the new duration with which tokens will be distributed to the staking contract
    /// @param _duration New duration
    /// @param stakingContract Reference to the staking contract
    function setDuration(uint256 _duration, IStakingRewards stakingContract) external override onlyRole(GUARDIAN_ROLE) {
        StakingParameters storage stakingParams = stakingContractsMap[stakingContract];
        require(stakingParams.duration > 0, "invalid staking contract");
        uint256 timeElapsed = _timeSinceStart(stakingParams);
        require(timeElapsed < stakingParams.duration && timeElapsed < _duration, "too high amount");
        stakingParams.duration = _duration;
        emit DurationUpdated(_duration, address(stakingContract));
    }

    // =========================== Internal Functions ==============================

    /// @notice Gives the next time when `drip` could be called
    /// @param stakingParams Parameters of the concerned staking contract
    /// @return Block timestamp when `drip` will next be available
    function _nextDripAvailable(StakingParameters memory stakingParams) internal pure returns (uint256) {
        return stakingParams.lastDistributionTime + stakingParams.updateFrequency;
    }

    /// @notice Tells if `drip` can currently be called
    /// @param stakingParams Parameters of the concerned staking contract
    /// @return If the `updateFrequency` has passed since the last drip
    function _isDripAvailable(StakingParameters memory stakingParams) internal view returns (bool) {
        return block.timestamp >= _nextDripAvailable(stakingParams);
    }

    /// @notice Computes the amount of tokens to give at the current drip
    /// @param stakingParams Parameters of the concerned staking contract
    /// @dev Constant drip amount across time
    function _computeDripAmount(StakingParameters memory stakingParams) internal view returns (uint256) {
        uint256 timeElapsed = _timeSinceStart(stakingParams);
        uint256 timeLeft = stakingParams.duration - timeElapsed;
        if (stakingParams.distributedRewards >= stakingParams.amountToDistribute || timeLeft == 0) {
            return 0;
        }
        uint256 rewardsLeftToDistribute = stakingParams.amountToDistribute - stakingParams.distributedRewards;

        if (timeLeft < stakingParams.updateFrequency) {
            return rewardsLeftToDistribute;
        } else {
            return (stakingParams.updateFrequency * rewardsLeftToDistribute) / timeLeft;
        }
    }

    /// @notice Computes the time since distribution has started for the staking contract
    /// @param stakingParams Parameters of the concerned staking contract
    /// @return The time since distribution has started for the staking contract
    function _timeSinceStart(StakingParameters memory stakingParams) internal view returns (uint256) {
        uint256 _duration = stakingParams.duration;
        // `block.timestamp` is always greater than `timeStarted`
        uint256 timePassed = block.timestamp - stakingParams.timeStarted;
        return timePassed > _duration ? _duration : timePassed;
    }

    /// @notice Incentivizes the person calling the drip function
    /// @param stakingParams Parameters of the concerned staking contract
    function _incentivize(StakingParameters memory stakingParams) internal {
        require(rewardToken.transfer(msg.sender, stakingParams.incentiveAmount), "ANGLE token transfer failed");
    }
}
