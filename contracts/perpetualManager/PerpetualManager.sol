// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PerpetualManagerInternal.sol";

/// @title PerpetualManager
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents positions and perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains the functions of the `PerpetualManager` that can be interacted with
/// by `StableMaster`, by the `PoolManager`, by the `FeeManager` and by governance
contract PerpetualManager is
    PerpetualManagerInternal,
    IPerpetualManagerFunctions,
    IStakingRewardsFunctions,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role for guardians, governors and `StableMaster`
    /// Made for the `StableMaster` to be able to update some parameters
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role for `PoolManager` only
    bytes32 public constant POOLMANAGER_ROLE = keccak256("POOLMANAGER_ROLE");

    // ============================== Modifiers ====================================

    /// @notice Checks if the person interacting with the perpetual with `perpetualID` is approved
    /// @param caller Address of the person seeking to interact with the perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @dev Generally in `PerpetualManager`, perpetual owners should store the ID of the perpetuals
    /// they are able to interact with
    modifier onlyApprovedOrOwner(address caller, uint256 perpetualID) {
        require(_isApprovedOrOwner(caller, perpetualID), "21");
        _;
    }

    /// @notice Checks if the message sender is the rewards distribution address
    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "1");
        _;
    }

    // =============================== Deployer ====================================

    /// @notice Notifies the address of the `_feeManager` and of the `oracle`
    /// to this contract and grants the correct roles
    /// @param governorList List of governor addresses of the protocol
    /// @param guardian Address of the guardian of the protocol
    /// @param feeManager_ Reference to the `FeeManager` contract which will be able to update fees
    /// @param oracle_ Reference to the `oracle` contract which will be able to update fees
    /// @dev Called by the `PoolManager` contract when it is activated by the `StableMaster`
    /// @dev The `governorList` and `guardian` here are those of the `Core` contract
    function deployCollateral(
        address[] memory governorList,
        address guardian,
        IFeeManager feeManager_,
        IOracle oracle_
    ) external override onlyRole(POOLMANAGER_ROLE) {
        for (uint256 i = 0; i < governorList.length; i++) {
            _grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        // In the end guardian should be revoked by governance
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(GUARDIAN_ROLE, address(_stableMaster));
        _feeManager = feeManager_;
        oracle = oracle_;
    }

    // ========================== Rewards Distribution =============================

    /// @notice Notifies the contract that rewards are going to be shared among HAs of this pool
    /// @param reward Amount of governance tokens to be distributed to HAs
    /// @dev Only the reward distributor contract is allowed to call this function which starts a staking cycle
    /// @dev This function is the equivalent of the `notifyRewardAmount` function found in all staking contracts
    function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution {
        rewardPerTokenStored = _rewardPerToken();

        if (block.timestamp >= periodFinish) {
            // If the period is not done, then the reward rate changes
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            // If the period is not over, we compute the reward left and increase reward duration
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // Ensuring the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of `rewardRate` in the earned and `rewardsPerToken` functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardToken.balanceOf(address(this));

        require(rewardRate <= balance / rewardsDuration, "22");

        lastUpdateTime = block.timestamp;
        // Change the duration
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    /// @notice Supports recovering LP Rewards from other systems such as BAL to be distributed to holders
    /// or tokens that were mistakenly
    /// @param tokenAddress Address of the token to transfer
    /// @param to Address to give tokens to
    /// @param tokenAmount Amount of tokens to transfer
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 tokenAmount
    ) external override onlyRewardsDistribution {
        require(tokenAddress != address(rewardToken), "20");
        IERC20(tokenAddress).safeTransfer(to, tokenAmount);
        emit Recovered(tokenAddress, to, tokenAmount);
    }

    /// @notice Changes the `rewardsDistribution` associated to this contract
    /// @param _rewardsDistribution Address of the new rewards distributor contract
    /// @dev This function is part of the staking rewards interface and it is used to propagate
    /// a change of rewards distributor notified by the current `rewardsDistribution` address
    /// @dev It has already been checked in the `RewardsDistributor` contract calling
    /// this function that the `newRewardsDistributor` had a compatible reward token
    /// @dev With this function, everything is as if `rewardsDistribution` was admin of its own role
    function setNewRewardsDistribution(address _rewardsDistribution) external override onlyRewardsDistribution {
        rewardsDistribution = _rewardsDistribution;
        emit RewardsDistributionUpdated(_rewardsDistribution);
    }

    // ================================= Keepers ===================================

    /// @notice Updates all the fees not depending on individual HA conditions via keeper utils functions
    /// @param feeDeposit New deposit global fees
    /// @param feeWithdraw New withdraw global fees
    /// @dev Governance may decide to incorporate a collateral ratio dependence in the fees for HAs,
    /// in this case it will be done through the `FeeManager` contract
    /// @dev This dependence can either be a bonus or a malus
    function setFeeKeeper(uint64 feeDeposit, uint64 feeWithdraw) external override {
        require(msg.sender == address(_feeManager), "1");
        haBonusMalusDeposit = feeDeposit;
        haBonusMalusWithdraw = feeWithdraw;
    }

    // ======== Governance - Guardian Functions - Staking and Pauses ===============

    /// @notice Pauses the `getReward` method as well as the functions allowing to open, modify or close perpetuals
    /// @dev After calling this function, it is going to be impossible for HAs to interact with their perpetuals
    /// or claim their rewards on it
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses HAs functions
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice Sets the conditions and specifies the duration of the reward distribution
    /// @param _rewardsDuration Duration for the rewards for this contract
    /// @param _rewardsDistribution Address which will give the reward tokens
    /// @dev It allows governance to directly change the rewards distribution contract and the conditions
    /// at which this distribution is done
    /// @dev The compatibility of the reward token is not checked here: it is checked
    /// in the rewards distribution contract when activating this as a staking contract,
    /// so if a reward distributor is set here but does not have a compatible reward token, then this reward
    /// distributor will not be able to set this contract as a staking contract
    function setRewardDistribution(uint256 _rewardsDuration, address _rewardsDistribution)
        external
        onlyRole(GUARDIAN_ROLE)
        zeroCheck(_rewardsDistribution)
    {
        rewardsDuration = _rewardsDuration;
        rewardsDistribution = _rewardsDistribution;
        emit RewardsDistributionDurationUpdated(rewardsDuration, rewardsDistribution);
    }

    // ============ Governance - Guardian Functions - Parameters ===================

    /// @notice Sets `baseURI` that is the URI to access ERC721 metadata
    /// @param _baseURI New `baseURI` parameter
    function setBaseURI(string memory _baseURI) external onlyRole(GUARDIAN_ROLE) {
        baseURI = _baseURI;
        emit BaseURIUpdated(_baseURI);
    }

    /// @notice Sets `lockTime` that is the minimum amount of time HAs have to stay within the protocol
    /// @param _lockTime New `lockTime` parameter
    /// @dev This parameter is used to prevent HAs from exiting before a certain amount of time and taking advantage
    /// of insiders' information they may have due to oracle latency
    function setLockTime(uint64 _lockTime) external override onlyRole(GUARDIAN_ROLE) {
        lockTime = _lockTime;
        emit LockTimeUpdated(_lockTime);
    }

    /// @notice Changes the maximum leverage authorized (commit/margin) and the maintenance margin under which
    /// perpetuals can be liquidated
    /// @param _maxLeverage New value of the maximum leverage allowed
    /// @param _maintenanceMargin The new maintenance margin
    /// @dev For a perpetual, the leverage is defined as the ratio between the committed amount and the margin
    /// @dev For a perpetual, the maintenance margin is defined as the ratio between the margin ratio / the committed amount
    function setBoundsPerpetual(uint64 _maxLeverage, uint64 _maintenanceMargin)
        external
        override
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_maintenanceMargin)
    {
        // Checking the compatibility of the parameters
        require(BASE_PARAMS**2 > _maxLeverage * _maintenanceMargin, "8");
        maxLeverage = _maxLeverage;
        maintenanceMargin = _maintenanceMargin;
        emit BoundsPerpetualUpdated(_maxLeverage, _maintenanceMargin);
    }

    /// @notice Sets `xHAFees` that is the thresholds of values of the ratio between what's covered (hedged)
    /// divided by what's to hedge with HAs at which fees will change as well as
    /// `yHAFees` that is the value of the deposit or withdraw fees at threshold
    /// @param _xHAFees Array of the x-axis value for the fees (deposit or withdraw)
    /// @param _yHAFees Array of the y-axis value for the fees (deposit or withdraw)
    /// @param deposit Whether deposit or withdraw fees should be updated
    /// @dev Evolution of the fees is linear between two values of thresholds
    /// @dev These x values should be ranked in ascending order
    /// @dev For deposit fees, the higher the x that is the ratio between what's to hedge and what's hedged
    /// the higher y should be (the more expensive it should be for HAs to come in)
    /// @dev For withdraw fees, evolution should follow an opposite logic
    function setHAFees(
        uint64[] memory _xHAFees,
        uint64[] memory _yHAFees,
        uint8 deposit
    ) external override onlyRole(GUARDIAN_ROLE) onlyCompatibleInputArrays(_xHAFees, _yHAFees) {
        if (deposit == 1) {
            xHAFeesDeposit = _xHAFees;
            yHAFeesDeposit = _yHAFees;
        } else {
            xHAFeesWithdraw = _xHAFees;
            yHAFeesWithdraw = _yHAFees;
        }
        emit HAFeesUpdated(_xHAFees, _yHAFees, deposit);
    }

    /// @notice Sets the target and limit proportions of collateral from users that can be insured by HAs
    /// @param _targetHAHedge Proportion of collateral from users that HAs should hedge
    /// @param _limitHAHedge Proportion of collateral from users above which HAs can see their perpetuals
    /// cashed out
    /// @dev `targetHAHedge` equal to `BASE_PARAMS` means that all the collateral from users should be insured by HAs
    /// @dev `targetHAHedge` equal to 0 means HA should not cover (hedge) anything
    function setTargetAndLimitHAHedge(uint64 _targetHAHedge, uint64 _limitHAHedge)
        external
        override
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_targetHAHedge)
        onlyCompatibleFees(_limitHAHedge)
    {
        require(_targetHAHedge <= _limitHAHedge, "8");
        limitHAHedge = _limitHAHedge;
        targetHAHedge = _targetHAHedge;
        // Updating the value in the `stableMaster` contract
        _stableMaster.setTargetHAHedge(_targetHAHedge);
        emit TargetAndLimitHAHedgeUpdated(_targetHAHedge, _limitHAHedge);
    }

    /// @notice Sets the portion of the leftover cash out amount of liquidated perpetuals that go to keepers
    /// @param _keeperFeesLiquidationRatio Proportion to keepers
    /// @dev This proportion should be inferior to `BASE_PARAMS`
    function setKeeperFeesLiquidationRatio(uint64 _keeperFeesLiquidationRatio)
        external
        override
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_keeperFeesLiquidationRatio)
    {
        keeperFeesLiquidationRatio = _keeperFeesLiquidationRatio;
        emit KeeperFeesLiquidationRatioUpdated(keeperFeesLiquidationRatio);
    }

    /// @notice Sets the maximum amounts going to the keepers when closing perpetuals
    /// because too much was hedged by HAs or when liquidating a perpetual
    /// @param _keeperFeesLiquidationCap Maximum reward going to the keeper liquidating a perpetual
    /// @param _keeperFeesClosingCap Maximum reward going to the keeper forcing the closing of an ensemble
    /// of perpetuals
    function setKeeperFeesCap(uint256 _keeperFeesLiquidationCap, uint256 _keeperFeesClosingCap)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        keeperFeesLiquidationCap = _keeperFeesLiquidationCap;
        keeperFeesClosingCap = _keeperFeesClosingCap;
        emit KeeperFeesCapUpdated(keeperFeesLiquidationCap, keeperFeesClosingCap);
    }

    /// @notice Sets the x-array (ie thresholds) for `FeeManager` when closing perpetuals and the y-array that is the
    /// value of the proportions of the fees going to keepers closing perpetuals
    /// @param _xKeeperFeesClosing Thresholds for closing fees
    /// @param _yKeeperFeesClosing Value of the fees at the different threshold values specified in `xKeeperFeesClosing`
    /// @dev The x thresholds correspond to values of the hedge ratio divided by two
    /// @dev `xKeeperFeesClosing` and `yKeeperFeesClosing` should have the same length
    function setKeeperFeesClosing(uint64[] memory _xKeeperFeesClosing, uint64[] memory _yKeeperFeesClosing)
        external
        override
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleInputArrays(_xKeeperFeesClosing, _yKeeperFeesClosing)
    {
        xKeeperFeesClosing = _xKeeperFeesClosing;
        yKeeperFeesClosing = _yKeeperFeesClosing;
        emit KeeperFeesClosingUpdated(xKeeperFeesClosing, yKeeperFeesClosing);
    }

    // ================ Governance - `PoolManager` Functions =======================

    /// @notice Changes the reference to the `FeeManager` contract
    /// @param feeManager_ New `FeeManager` contract
    /// @dev This allows the `PoolManager` contract to propagate changes to the `PerpetualManager`
    /// @dev This is the only place where the `_feeManager` can be changed, it is as if there was
    /// a `FEEMANAGER_ROLE` for which `PoolManager` was the admin
    function setFeeManager(IFeeManager feeManager_) external override onlyRole(POOLMANAGER_ROLE) {
        _feeManager = feeManager_;
    }

    // ======================= `StableMaster` Function =============================

    /// @notice Changes the oracle contract used to compute collateral price with respect to the stablecoin's price
    /// @param oracle_ Oracle contract
    /// @dev The collateral `PoolManager` does not store a reference to an oracle, the value of the oracle
    /// is hence directly set by the `StableMaster`
    function setOracle(IOracle oracle_) external override {
        require(msg.sender == address(_stableMaster), "1");
        oracle = oracle_;
    }
}
