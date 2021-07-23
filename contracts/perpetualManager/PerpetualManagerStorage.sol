// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./PerpetualManagerEvents.sol";

struct Perpetual {
    uint256 initialRate;
    uint256 cashOutAmount;
    uint256 committedAmount;
    uint256 creationBlock;
    uint256 fees;
}

/// @title PerpetualManagerStorage
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents positions and perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains all the parameters and references used in the `PerpetualManager` contract
contract PerpetualManagerStorage is PerpetualManagerEvents, FunctionUtils {
    // Base used in the collateral implementation (ERC20 decimal)
    uint256 internal _collatBase;

    // ============================== Perpetual Variables ==========================

    /// @notice Total committed amount for this pool stablecoin / collateral
    /// It corresponds to the sum of committed amounts across all perpetuals and reflects
    /// the amount of collateral brought by users that is covered by Hedging Agents
    uint256 public totalCAmount;

    // Counter to generate a unique `perpetualID` for each perpetual
    CountersUpgradeable.Counter internal _perpetualIDcount;

    // ========================== Changeable References ============================

    // `Oracle` to give the rate feed, that is the price of the collateral
    // with respect to the price of the stablecoin
    // This reference can be modified by the associated `PoolManager` contract
    IOracle internal _oracle;

    // Keeper address allowed to update the fees for this contract
    // This reference can be modified by the `StableMaster` contract
    IFeeManager internal _feeManager;

    // ========================== Unchangeable References ==========================

    /// @notice Interface for the `rewardToken` distributed as a reward
    /// As of Angle V1, only a single `rewardToken` can be distributed to HAs who own a perpetual
    IERC20 public rewardToken;

    /// @notice Address of the `PoolManager` instance
    IPoolManager public poolManager;

    // Address of the `StableMaster` instance
    IStableMaster internal _stableMaster;

    // Interface for the underlying token accepted by this contract
    // This reference cannot be changed, it is taken from the `PoolManager`
    IERC20 internal _token;

    // ======================= Fees and other Parameters ===========================

    /// @notice Max proportion of collateral from users that can be covered by HAs
    uint256 public maxALock;

    /// @notice Deposit fees for HAs depend on the gap to reach full HA coverage
    /// that is the difference between what is to cover and what is covered by HAs
    /// Thresholds for the ratio between gap to full HA coverage and amount to cover
    /// The smaller the gap the bigger the fees will be because this means that the max amount
    /// to insure is soon to be reached
    uint256[] public xHAFeesDeposit;

    /// @notice Deposit fees at threshold values
    /// This array should have the same length as the array above
    /// The evolution of the fees between two threshold values is linear
    uint256[] public yHAFeesDeposit;

    /// @notice Withdraw fees for HAs also depend on the gap to reach full HA coverage
    /// Thresholds for the ratio between gap to full HA coverage and amount to cover
    uint256[] public xHAFeesWithdraw;

    /// @notice Withdraw fees at threshold values
    uint256[] public yHAFeesWithdraw;

    /// @notice Extra parameter from the `FeeManager` contract that is multiplied to the fees from above and that
    /// can be used to change deposit fees. It works as a bonus - malus fee, if `haBonusMalusDeposit > BASE`,
    /// then the fee will be larger than `haFeesDeposit`, if `haBonusMalusDeposit < BASE`, fees will be smaller.
    /// This parameter, updated by keepers in the `FeeManager` contract, could most likely depend on the collateral ratio
    uint256 public haBonusMalusDeposit;

    /// @notice Extra parameter from the `FeeManager` contract that is multiplied to the fees from above and that
    /// can be used to change withdraw fees. It works as a bonus - malus fee, if `haBonusMalusWithdraw > BASE`,
    /// then the fee will be larger than `haFeesWithdraw`, if `haBonusMalusWithdraw < BASE`, fees will be smaller
    uint256 public haBonusMalusWithdraw;

    /// @notice Amount of time before a HA is allowed to withdraw funds
    uint256 public secureBlocks;

    /// @notice Maximum leverage multiplier authorized for HAs
    /// Leverage here corresponds to the ratio between the amount committed and the cash out amount of the vault
    uint256 public maxLeverage;

    /// @notice Leverage at which keepers can cash out HAs
    uint256 public cashOutLeverage;

    /// @notice Maintenance Margin (in `BASE`) - if the current `cashOutAmount` is inferior to the initial `cashOutAmount`
    /// times `maintenanceMargin`, then a perpetual can be liquidated
    uint256 public maintenanceMargin;

    // ================================= Keeper fees ======================================
    // All these parameters can be modified by their corresponding governance function

    /// @notice Portion of the fees that go to keepers liquidating HA perpetuals
    uint256 public keeperFeesRatio;

    /// @notice Cap on the fees that go to keepers cashing out perpetuals when too much collateral
    /// is covered by HAs
    uint256 public keeperFeesCap;

    /// @notice Thresholds on the values of the rate between what has been committed by a perpetual cashed out
    /// and the spread `|amount currently covered by HAs - amount HAs should cover|`
    uint256[] public xKeeperFeesCashOut;

    /// @notice Values at thresholds of the proportions of the fees that should go to keepers cashing out perpetuals
    uint256[] public yKeeperFeesCashOut;

    // =========================== Staking Parameters ==============================

    /// @notice Below are parameters that can also be found in other staking contracts
    /// to be able to compute rewards from staking (having perpetuals here) correctly
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    address public rewardsDistribution;

    // =============================== Mappings ====================================

    /// @notice Mapping from `perpetualID` to perpetual data
    mapping(uint256 => Perpetual) public perpetualData;

    /// @notice Mapping used to compute the rewards earned by a perpetual in a timeframe
    mapping(uint256 => uint256) public perpetualRewardPerTokenPaid;

    /// @notice Mapping used to get how much rewards in governance tokens are gained by a perpetual
    // identified by its ID
    mapping(uint256 => uint256) public rewards;

    // Mapping from `perpetualID` to owner address
    mapping(uint256 => address) internal _owners;

    // Mapping from owner address to perpetual owned count
    mapping(address => uint256) internal _balances;

    // Mapping from `perpetualID` to approved address
    mapping(uint256 => address) internal _perpetualApprovals;

    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) internal _operatorApprovals;
}
