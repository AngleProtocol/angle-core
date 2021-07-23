// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./PerpetualManagerInternal.sol";

/// @title PerpetualManager
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents positions and perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains the functions of the `PerpetualManager` that can be interacted with
/// by `StableMaster`, by the `PoolManager`, by the `FeeManager` and by governance
contract PerpetualManager is
    PerpetualManagerInternal,
    IPerpetualManager,
    IStakingRewards,
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
        require(_isApprovedOrOwner(caller, perpetualID), "caller not approved");
        _;
    }

    /// @notice Checks if the perpetual of interest really exists
    /// @param perpetualID ID of the concerned perpetual
    modifier onlyExistingPerpetual(uint256 perpetualID) {
        require(_exists(perpetualID), "nonexistent perpetual");
        _;
    }

    /// @notice Checks if the message sender is the rewards distribution address
    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "incorrect sender");
        _;
    }

    // =============================== Deployer ====================================

    /// @notice Notifies the address of the collateral `PoolManager` to this contract and grants the correct roles
    /// @param governorList List of governor addresses of the protocol
    /// @param guardian Address of the guardian of the protocol
    /// @param feeManager_ Reference to the `FeeManager` contract which will be able to update fees
    /// @dev Called by the `PoolManager` contract when it is activated by the `StableMaster`
    /// @dev The `governorList` and `guardian` here are those of the `Core` contract
    function deployCollateral(
        address[] memory governorList,
        address guardian,
        IFeeManager feeManager_
    ) external override onlyRole(POOLMANAGER_ROLE) {
        for (uint256 i = 0; i < governorList.length; i++) {
            grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        // In the end guardian should be revoked by governance
        grantRole(GUARDIAN_ROLE, guardian);
        grantRole(GUARDIAN_ROLE, address(_stableMaster));
        _feeManager = feeManager_;
    }

    // ========================== Rewards Distribution =============================

    /// @notice Notifies the contract that rewards are going to be shared among HAs of this pool
    /// @param reward Amount of governance tokens to be distributed to HAs
    /// @dev Only the reward distributor contract is allowed to call this function which starts a staking cycle
    /// @dev This function is the equivalent of the `notifyRewardAmount` function found in all staking contracts
    function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();

        if (block.timestamp >= periodFinish) {
            // If the period is not done, then the reward rate changes
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            // If the period is not over, we compute the reward left and increase reward duration
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of `rewardRate` in the earned and `rewardsPerToken` functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardToken.balanceOf(address(this));
        // This condition is always going to be checked with the `RewardsDistributor` contract
        // we have at this point as `reward` token are always sent before calling `notifyRewardAmount`
        require(rewardRate <= balance / rewardsDuration, "reward too high");

        lastUpdateTime = block.timestamp;
        // Change the duration
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    /// @notice Supports recovering LP Rewards from other systems such as BAL to be distributed to holders
    /// @param tokenAddress Address of the token to transfer
    /// @param to Address to give tokens to
    /// @param tokenAmount Amount of tokens to transfer
    /// @dev Function left here because it has to be part of the interface of staking contracts
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 tokenAmount
    ) external override onlyRewardsDistribution {
        require(tokenAddress != address(rewardToken), "Cannot withdraw the rewards token");
        IERC20(tokenAddress).safeTransfer(to, tokenAmount);
    }

    /// @notice Changes the `rewardsDistribution` associated to this contract
    /// @param newRewardsDistributor Address of the new rewards distributor contract
    /// @dev This function is part of the staking rewards interface and it is used to propagate
    /// a change of rewards distributor
    /// @dev A zero address check has already been performed in the `RewardsDistributor` contract calling
    /// this function
    function setNewRewardsDistributor(address newRewardsDistributor) external override onlyRewardsDistribution {
        require(
            address(IRewardsDistributor(newRewardsDistributor).rewardToken()) == address(rewardToken),
            "incompatible reward tokens"
        );
        // Everything is as if `rewardsDistribution` was admin of its own role
        rewardsDistribution = newRewardsDistributor;
        emit RewardsDistributorUpdated(newRewardsDistributor);
    }

    // ================================= Keepers ===================================

    /// @notice Updates all the fees not depending on individual HA conditions via keeper utils functions
    /// @param feeDeposit New deposit global fees
    /// @param feesWithdraw New withdraw global fees
    /// @dev Governance may decide to incorporate a collateral ratio dependence in the fees for HAs,
    /// in this case it will be done through the `FeeManager` contract
    /// @dev This dependence can either be a bonus or a malus
    function setFeeKeeper(uint256 feeDeposit, uint256 feesWithdraw) external override {
        require(msg.sender == address(_feeManager), "incorrect sender");
        haBonusMalusDeposit = feeDeposit;
        haBonusMalusWithdraw = feesWithdraw;
    }

    // ======== Governance - Guardian Functions - Staking and Pauses ===============

    /// @notice Pauses the `getReward` method as well as the functions allowing to create, modify or cash-out perpetuals
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
    /// @dev It allows governance to directly change the rewards distribution contract
    function setRewardDistribution(uint256 _rewardsDuration, address _rewardsDistribution)
        external
        onlyRole(GUARDIAN_ROLE)
        zeroCheck(_rewardsDistribution)
    {
        require(
            address(IRewardsDistributor(_rewardsDistribution).rewardToken()) == address(rewardToken),
            "incompatible reward tokens"
        );
        rewardsDuration = _rewardsDuration;
        rewardsDistribution = _rewardsDistribution;
        emit RewardDistributionUpdated(rewardsDuration, rewardsDistribution);
    }

    // ============ Governance - Guardian Functions - Parameters ===================

    /// @notice Sets `secureBlocks` that is the minimum amount of time HAs have to stay within the protocol
    /// @param _secureBlocks New `secureBlocks` parameter
    /// @dev This parameter is used to prevent HAs from exiting after a certain amount of time and taking advantage
    /// of insiders' information they may have due to oracle latency
    function setSecureBlocks(uint256 _secureBlocks) external onlyRole(GUARDIAN_ROLE) {
        secureBlocks = _secureBlocks;
        emit SecureBlocksUpdated(_secureBlocks);
    }

    /// @notice Changes the maximum leverage authorized (commit/brought)
    /// @param newMaxLeverage New value of the maximum leverage allowed
    /// @dev For a perpetual, the leverage is defined as the ratio between the committed amount and the brought
    /// amount
    function setMaxLeverage(uint256 newMaxLeverage) external onlyRole(GUARDIAN_ROLE) {
        maxLeverage = newMaxLeverage;
        emit MaxLeverageUpdated(maxLeverage);
    }

    /// @notice Changes the leverage at which keepers can cash out a perpetual
    /// @param _cashOutLeverage New cash out leverage
    /// @dev If the ratio between a committed amount and the brought amount of a perpetual is below the threshold
    /// defined by `cashOutLeverage, then this perpetual can get liquidated.
    function setCashOutLeverage(uint256 _cashOutLeverage) external onlyRole(GUARDIAN_ROLE) {
        require(_cashOutLeverage > maxLeverage, "cashOutLeverage too low");
        cashOutLeverage = _cashOutLeverage;
        emit CashOutLeverageUpdated(cashOutLeverage);
    }

    /// @notice Changes the maintenance margin
    /// @param _maintenanceMargin The new maintenance margin
    function setMaintenanceMargin(uint256 _maintenanceMargin)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_maintenanceMargin)
    {
        maintenanceMargin = _maintenanceMargin;
        emit MaintenanceMarginUpdated(maintenanceMargin);
    }

    /// @notice Sets `xHAFees` that is the thresholds of values of the gap of collateral
    /// left to cover divided by what's to cover by HAs at which fees will change as well as
    /// `yHAFees` that is the value of the deposit or withdraw fees at threshold
    /// @param _xHAFees Array of the x-axis value for the fees (deposit or withdraw)
    /// @param _yHAFees Array of the y-axis value for the fees (deposit or withdraw)
    /// @param deposit Whether deposit or withdraw fees should be updated
    /// @dev Evolution of the fees is linear between two values of thresholds
    /// @dev These x values should be ranked in ascending order
    /// @dev For deposit fees, the higher the x that is the margin between what's to cover and what's covered
    /// the lower y should be
    /// @dev For withdraw fees, evolution should follow an opposite logic
    function setHAFees(
        uint256[] memory _xHAFees,
        uint256[] memory _yHAFees,
        uint256 deposit
    ) external onlyRole(GUARDIAN_ROLE) onlyCompatibleInputArrays(_xHAFees, _yHAFees, true) {
        if (deposit == 1) {
            xHAFeesDeposit = _xHAFees;
            yHAFeesDeposit = _yHAFees;
            emit HAFeesDepositUpdated(_xHAFees, _yHAFees);
        } else {
            xHAFeesWithdraw = _xHAFees;
            yHAFeesWithdraw = _yHAFees;
            emit HAFeesWithdrawUpdated(_xHAFees, _yHAFees);
        }
    }

    /// @notice Sets the proportion of `stocksUsers` that is the collateral from users that can be insured by HA
    /// @param _maxALock Proportion of collateral from users that HAs can cover
    /// @dev `maxALock` equal to `BASE` means all the collateral from users can be insured by HAs
    /// @dev `maxALock` equal to 0 means HA cannot cover anything
    function setMaxALock(uint256 _maxALock) external onlyRole(GUARDIAN_ROLE) onlyCompatibleFees(_maxALock) {
        maxALock = _maxALock;
        emit MaxALockUpdated(maxALock);
    }

    /// @notice Sets the proportion of fees going to the keepers when liquidating a HA perpetual
    /// @param _keeperFeesRatio Proportion to keepers
    /// @dev This proportion should be inferior to `BASE`
    function setKeeperFeesRatio(uint256 _keeperFeesRatio)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_keeperFeesRatio)
    {
        keeperFeesRatio = _keeperFeesRatio;
        emit KeeperFeesRatioUpdated(keeperFeesRatio);
    }

    /// @notice Sets the maximum amount going to the keepers when cashing out an external user
    /// because too much was covered by HAs
    /// @param _keeperFeesCap Maximum reward going to the keeper
    function setKeeperFeesCap(uint256 _keeperFeesCap) external onlyRole(GUARDIAN_ROLE) {
        keeperFeesCap = _keeperFeesCap;
        emit KeeperFeesCapUpdated(keeperFeesCap);
    }

    /// @notice Sets the x-array (ie thresholds) for `FeeManagerù when cashing out perpetuals and the y-array that is the
    /// value of the proportions of the fees going to keepers cashing out perpetuals
    /// @param _xKeeperFeesCashOut Thresholds for cash out fees
    /// @param _yKeeperFeesCashOut Value of the fees at the different threshold values specified in `xKeeperFeesCashOut`
    /// @dev The x thresholds correspond to different values of the ratio between the amount that is covered
    /// by a perpetual and the surplus amount that HAs cover and that should not be covered
    /// @dev `xKeeperFeesCashOut` and `yKeeperFeesCashOut` should have the same length
    function setKeeperFeesCashOut(uint256[] memory _xKeeperFeesCashOut, uint256[] memory _yKeeperFeesCashOut)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleInputArrays(_xKeeperFeesCashOut, _yKeeperFeesCashOut, true)
    {
        xKeeperFeesCashOut = _xKeeperFeesCashOut;
        yKeeperFeesCashOut = _yKeeperFeesCashOut;
        emit KeeperFeesCashOutUpdated(xKeeperFeesCashOut, yKeeperFeesCashOut);
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

    // ======================= `StableMaster` Functions ============================

    /// @notice Changes the oracle contract used to compute collateral price with respect to the stablecoin's price
    /// @param oracle_ Oracle contract
    /// @dev The collateral `PoolManager` does not store a reference to an oracle, the value of the oracle
    /// is hence directly set by the `StableMaster`
    function setOracle(IOracle oracle_) external override {
        require(msg.sender == address(_stableMaster), "incorrect sender");
        // The `inBase` of the new oracle should be the same as the `_collatBase` stored for this collateral
        require(_collatBase == oracle_.getInBase(), "incorrect oracle base");
        _oracle = oracle_;
    }

    /// @notice Gets the `maxAlock` and total amount of collateral covered by HAs
    /// @return maxALock Max proportion of collateral from users that can be covered by HAs
    /// @return totalCAmount Amount of collateral covered by HAs
    /// @dev This function is among other things called by the `StableMaster` contract to compute the mint fees for users
    function getCoverageInfo() external view override returns (uint256, uint256) {
        return (maxALock, totalCAmount);
    }
}
