// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./StakingRewardsEvents.sol";

/// @title StakingRewards
/// @author Forked form SetProtocol
/// https://github.com/SetProtocol/index-coop-contracts/blob/master/contracts/staking/StakingRewards.sol
/// @notice The `StakingRewards` contracts allows to stake an ERC20 token to receive as reward another ERC20
/// @dev This contracts is managed by the reward distributor and implements the staking interface
contract StakingRewards is StakingRewardsEvents, IStakingRewards, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Checks to see if it is the `rewardsDistribution` calling this contract
    /// @dev There is no Access Control here, because it can be handled cheaply through these modifiers
    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "1");
        _;
    }

    // ============================ References to contracts ========================

    /// @notice ERC20 token given as reward
    IERC20 public immutable override rewardToken;

    /// @notice ERC20 token used for staking
    IERC20 public immutable stakingToken;

    /// @notice Base of the staked token, it is going to be used in the case of sanTokens
    /// which are not in base 10**18
    uint256 public immutable stakingBase;

    /// @notice Rewards Distribution contract for this staking contract
    address public rewardsDistribution;

    // ============================ Staking parameters =============================

    /// @notice Time at which distribution ends
    uint256 public periodFinish;

    /// @notice Reward per second given to the staking contract, split among the staked tokens
    uint256 public rewardRate;

    /// @notice Duration of the reward distribution
    uint256 public rewardsDuration;

    /// @notice Last time `rewardPerTokenStored` was updated
    uint256 public lastUpdateTime;

    /// @notice Helps to compute the amount earned by someone
    /// Cumulates rewards accumulated for one token since the beginning.
    /// Stored as a uint so it is actually a float times the base of the reward token
    uint256 public rewardPerTokenStored;

    /// @notice Stores for each account the `rewardPerToken`: we do the difference
    /// between the current and the old value to compute what has been earned by an account
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Stores for each account the accumulated rewards
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;

    // ============================ Constructor ====================================

    /// @notice Initializes the staking contract with a first set of parameters
    /// @param _rewardsDistribution Address owning the rewards token
    /// @param _rewardToken ERC20 token given as reward
    /// @param _stakingToken ERC20 token used for staking
    /// @param _rewardsDuration Duration of the staking contract
    constructor(
        address _rewardsDistribution,
        address _rewardToken,
        address _stakingToken,
        uint256 _rewardsDuration
    ) {
        require(_stakingToken != address(0) && _rewardToken != address(0) && _rewardsDistribution != address(0), "0");

        // We are not checking the compatibility of the reward token between the distributor and this contract here
        // because it is checked by the `RewardsDistributor` when activating the staking contract
        // Parameters
        rewardToken = IERC20(_rewardToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDuration = _rewardsDuration;
        rewardsDistribution = _rewardsDistribution;

        stakingBase = 10**IERC20Metadata(_stakingToken).decimals();
    }

    // ============================ Modifiers ======================================

    /// @notice Checks to see if the calling address is the zero address
    /// @param account Address to check
    modifier zeroCheck(address account) {
        require(account != address(0), "0");
        _;
    }

    /// @notice Called frequently to update the staking parameters associated to an address
    /// @param account Address of the account to update
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ============================ View functions =================================

    /// @notice Accesses the total supply
    /// @dev Used instead of having a public variable to respect the ERC20 standard
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Accesses the number of token staked by an account
    /// @param account Account to query the balance of
    /// @dev Used instead of having a public variable to respect the ERC20 standard
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Queries the last timestamp at which a reward was distributed
    /// @dev Returns the current timestamp if a reward is being distributed and the end of the staking
    /// period if staking is done
    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    /// @notice Used to actualize the `rewardPerTokenStored`
    /// @dev It adds to the reward per token: the time elapsed since the `rewardPerTokenStored` was
    /// last updated multiplied by the `rewardRate` divided by the number of tokens
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * stakingBase) / _totalSupply);
    }

    /// @notice Returns how much a given account earned rewards
    /// @param account Address for which the request is made
    /// @return How much a given account earned rewards
    /// @dev It adds to the rewards the amount of reward earned since last time that is the difference
    /// in reward per token from now and last time multiplied by the number of tokens staked by the person
    function earned(address account) public view returns (uint256) {
        return
            (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) /
            stakingBase +
            rewards[account];
    }

    // ======================== Mutative functions forked ==========================

    /// @notice Lets someone stake a given amount of `stakingTokens`
    /// @param amount Amount of ERC20 staking token that the `msg.sender` wants to stake
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        _stake(amount, msg.sender);
    }

    /// @notice Lets a user withdraw a given amount of collateral from the staking contract
    /// @param amount Amount of the ERC20 staking token that the `msg.sender` wants to withdraw
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "89");
        _totalSupply = _totalSupply - amount;
        _balances[msg.sender] = _balances[msg.sender] - amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Triggers a payment of the reward earned to the msg.sender
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Exits someone
    /// @dev This function lets the caller withdraw its staking and claim rewards
    // Attention here, there may be reentrancy attacks because of the following call
    // to an external contract done before other things are modified, yet since the `rewardToken`
    // is mostly going to be a trusted contract controlled by governance (namely the ANGLE token),
    // this is not an issue. If the `rewardToken` changes to an untrusted contract, this need to be updated.
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // ====================== Functions added by Angle Core Team ===================

    /// @notice Allows to stake on behalf of another address
    /// @param amount Amount to stake
    /// @param onBehalf Address to stake onBehalf of
    function stakeOnBehalf(uint256 amount, address onBehalf)
        external
        nonReentrant
        zeroCheck(onBehalf)
        updateReward(onBehalf)
    {
        _stake(amount, onBehalf);
    }

    /// @notice Internal function to stake called by `stake` and `stakeOnBehalf`
    /// @param amount Amount to stake
    /// @param onBehalf Address to stake on behalf of
    /// @dev Before calling this function, it has already been verified whether this address was a zero address or not
    function _stake(uint256 amount, address onBehalf) internal {
        require(amount > 0, "90");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        _totalSupply = _totalSupply + amount;
        _balances[onBehalf] = _balances[onBehalf] + amount;
        emit Staked(onBehalf, amount);
    }

    // ====================== Restricted Functions =================================

    /// @notice Adds rewards to be distributed
    /// @param reward Amount of reward tokens to distribute
    /// @dev This reward will be distributed during `rewardsDuration` set previously
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyRewardsDistribution
        nonReentrant
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            // If no reward is currently being distributed, the new rate is just `reward / duration`
            rewardRate = reward / rewardsDuration;
        } else {
            // Otherwise, cancel the future reward and add the amount left to distribute to reward
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Ensures the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of `rewardRate` in the earned and `rewardsPerToken` functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardToken.balanceOf(address(this));
        require(rewardRate <= balance / rewardsDuration, "91");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration; // Change the duration
        emit RewardAdded(reward);
    }

    /// @notice Withdraws ERC20 tokens that could accrue on this contract
    /// @param tokenAddress Address of the ERC20 token to withdraw
    /// @param to Address to transfer to
    /// @param amount Amount to transfer
    /// @dev A use case would be to claim tokens if the staked tokens accumulate rewards
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amount
    ) external override onlyRewardsDistribution {
        require(tokenAddress != address(stakingToken) && tokenAddress != address(rewardToken), "20");

        IERC20(tokenAddress).safeTransfer(to, amount);
        emit Recovered(tokenAddress, to, amount);
    }

    /// @notice Changes the rewards distributor associated to this contract
    /// @param _rewardsDistribution Address of the new rewards distributor contract
    /// @dev This function was also added by Angle Core Team
    /// @dev A compatibility check of the reward token is already performed in the current `RewardsDistributor` implementation
    /// which has right to call this function
    function setNewRewardsDistribution(address _rewardsDistribution) external override onlyRewardsDistribution {
        rewardsDistribution = _rewardsDistribution;
        emit RewardsDistributionUpdated(_rewardsDistribution);
    }
}
