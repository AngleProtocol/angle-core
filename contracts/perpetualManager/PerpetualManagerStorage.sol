// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./PerpetualManagerEvents.sol";

struct Perpetual {
    // Oracle value at the moment of perpetual creation
    uint256 entryRate;
    // Timestamp at which the perpetual was created
    uint256 entryTimestamp;
    // Amount initially brought in the perpetual (net from fees) + amount added - amount removed from it
    // This is the only element that can be modified in the perpetual after its creation
    uint256 margin;
    // Amount covered by the perpetual. This cannot be modified once the perpetual is created
    uint256 committedAmount;
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

    /// @notice Total amount of stablecoins that are insured (i.e. that could be redeemed against
    /// collateral thanks to HAs)
    /// When a HA opens a perpetual, it covers a fixed amount of stablecoins for the protocol, equal to
    /// the committed amount times the entry rate
    /// `totalCoveredAmount` is the sum of all these covered amounts
    uint256 public totalCoveredAmount;

    // Counter to generate a unique `perpetualID` for each perpetual
    CountersUpgradeable.Counter internal _perpetualIDcount;

    // ========================== Mutable References ============================

    /// @notice `Oracle` to give the rate feed, that is the price of the collateral
    /// with respect to the price of the stablecoin
    /// This reference can be modified by the corresponding `StableMaster` contract
    IOracle public oracle;

    // `FeeManager` address allowed to update the way fees are computed for this contract
    // This reference can be modified by the `PoolManager` contract
    IFeeManager internal _feeManager;

    // ========================== Immutable References ==========================

    /// @notice Interface for the `rewardToken` distributed as a reward
    /// As of Angle V1, only a single `rewardToken` can be distributed to HAs who own a perpetual
    /// This implementation assumes that reward tokens have a base of 18 decimals
    IERC20 public rewardToken;

    /// @notice Address of the `PoolManager` instance
    IPoolManager public poolManager;

    // Address of the `StableMaster` instance
    IStableMaster internal _stableMaster;

    // Interface for the underlying token accepted by this contract
    // This reference cannot be changed, it is taken from the `PoolManager`
    IERC20 internal _token;

    // ======================= Fees and other Parameters ===========================

    /// Deposit fees for HAs depend on the coverage ratio that is the ratio between what is covered
    /// by HAs compared with the total amount to cover
    /// @notice Thresholds for the ratio between to amount covered and the amount to cover
    /// The bigger the ratio the bigger the fees will be because this means that the max amount
    /// to insure is soon to be reached
    uint64[] public xHAFeesDeposit;

    /// @notice Deposit fees at threshold values
    /// This array should have the same length as the array above
    /// The evolution of the fees between two threshold values is linear
    uint64[] public yHAFeesDeposit;

    /// Withdraw fees for HAs also depend on the coverage ratio
    /// @notice Thresholds for the coverage ratio
    uint64[] public xHAFeesWithdraw;

    /// @notice Withdraw fees at threshold values
    uint64[] public yHAFeesWithdraw;

    /// @notice Maintenance Margin (in `BASE_PARAMS`) for this perpetual
    /// The margin ratio is defined for a perpetual as: `(initMargin + PnL) / committedAmount` where
    /// `PnL = committedAmount * (1 - initRate/currentRate)`
    /// If the `marginRatio` is below `maintenanceMargin`: then the perpetual can be liquidated
    uint64 public maintenanceMargin;

    /// @notice Maximum leverage multiplier authorized for HAs (`in BASE_PARAMS`)
    /// Leverage for a perpetual here corresponds to the ratio between the amount committed
    /// and the margin of the perpetual
    uint64 public maxLeverage;

    /// @notice Target proportion of stablecoins issued using this collateral to insure with HAs.
    /// This variable is exactly the same as the one in the `StableMaster` contract for this collateral.
    /// Above this proportion of coverage, HAs cannot open new perpetuals
    /// When keepers are forcing the cash out of some perpetuals, they are incentivized to bringing
    /// the coverage ratio to this proportion
    uint64 public targetHACoverage;

    /// @notice Limit proportion of stablecoins issued using this collateral that HAs can insure
    /// Above this ratio `forceCashOut` is activated and anyone can see its perpetual cashed out
    uint64 public limitHACoverage;

    /// @notice Extra parameter from the `FeeManager` contract that is multiplied to the fees from above and that
    /// can be used to change deposit fees. It works as a bonus - malus fee, if `haBonusMalusDeposit > BASE_PARAMS`,
    /// then the fee will be larger than `haFeesDeposit`, if `haBonusMalusDeposit < BASE_PARAMS`, fees will be smaller.
    /// This parameter, updated by keepers in the `FeeManager` contract, could most likely depend on the collateral ratio
    uint64 public haBonusMalusDeposit;

    /// @notice Extra parameter from the `FeeManager` contract that is multiplied to the fees from above and that
    /// can be used to change withdraw fees. It works as a bonus - malus fee, if `haBonusMalusWithdraw > BASE_PARAMS`,
    /// then the fee will be larger than `haFeesWithdraw`, if `haBonusMalusWithdraw < BASE_PARAMS`, fees will be smaller
    uint64 public haBonusMalusWithdraw;

    /// @notice Amount of time before a HA is allowed to withdraw funds from its perpetual
    /// either through `removeFromPerpetual` or from `cashOutPerpetual`. New perpetuals cannot be forced cash out in
    /// situations where the `forceCashOutPerpetuals` function is activated
    uint256 public lockTime;

    // ================================= Keeper fees ======================================
    // All these parameters can be modified by their corresponding governance function

    /// @notice Cap on the fees that go to keepers liquidating a perpetual
    /// If a keeper liquidates n perpetuals in a single transaction, then this keeper is entitled to get as much as
    /// `n * keeperFeesLiquidationCap` as a reward
    uint256 public keeperFeesLiquidationCap;

    /// @notice Cap on the fees that go to keepers cashing out perpetuals when too much collateral is covered by HAs
    /// (coverage ratio above `limitHACoverage`)
    /// If a keeper forces the cash out of n perpetuals in a single transaction, then this keeper is entitled to get
    /// as much as `keeperFeesCashOutCap`, this cap amount is independent of the number of perpetuals cashed out
    uint256 public keeperFeesCashOutCap;

    /// @notice Portion of the fees that go to keepers liquidating HA perpetuals
    uint64 public keeperFeesRatio;

    /// @notice Thresholds on the values of the rate between the current covered amount (`totalCoveredAmount`) and the
    /// target covered amount by HAs (`targetCoveredAmount`) divided by 2. A value of `0.5` corresponds to a coverage ratio
    /// of `1`. Doing this allows to maintain an array with values of `x` inferior to `BASE_PARAMS`.
    uint64[] public xKeeperFeesCashOut;

    /// @notice Values at thresholds of the proportions of the fees that should go to keepers cashing out perpetuals
    uint64[] public yKeeperFeesCashOut;

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
