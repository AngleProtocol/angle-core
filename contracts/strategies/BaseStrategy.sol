// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./BaseStrategyEvents.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title BaseStrategy
/// @author Forked from https://github.com/yearn/yearn-managers/blob/master/contracts/BaseStrategy.sol
/// @notice `BaseStrategy` implements all of the required functionalities to interoperate
/// with the `PoolManager` Contract.
/// @dev This contract should be inherited and the abstract methods implemented to adapt the `Strategy`
/// to the particular needs it has to create a return.
abstract contract BaseStrategy is BaseStrategyEvents, AccessControl {
    using SafeERC20 for IERC20;

    uint256 public constant BASE = 10**18;
    uint256 public constant SECONDSPERYEAR = 31556952;

    /// @notice Role for `PoolManager` only
    bytes32 public constant POOLMANAGER_ROLE = keccak256("POOLMANAGER_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ======================== References to contracts ============================

    /// @notice Reference to the protocol's collateral `PoolManager`
    IPoolManager public poolManager;

    /// @notice Reference to the ERC20 farmed by this strategy
    IERC20 public want;

    /// @notice Base of the ERC20 token farmed by this strategy
    uint256 public wantBase;

    //@notice Reference to the ERC20 distributed as a reward by the strategy
    IERC20 public rewards;

    // ============================ Parameters =====================================

    /// @notice The minimum number of seconds between harvest calls. See
    /// `setMinReportDelay()` for more details
    uint256 public minReportDelay;

    /// @notice The maximum number of seconds between harvest calls. See
    /// `setMaxReportDelay()` for more details
    uint256 public maxReportDelay;

    /// @notice Use this to adjust the threshold at which running a debt causes a
    /// harvest trigger. See `setDebtThreshold()` for more details
    uint256 public debtThreshold;

    /// @notice See note on `setEmergencyExit()`
    bool public emergencyExit;

    /// @notice The minimum amount moved for a call to `havest` to
    /// be "justifiable". See `setRewardAmountAndMinimumAmountMoved()` for more details
    uint256 public minimumAmountMoved;

    /// @notice Reward obtained by calling harvest
    /// @dev If this is null rewards are not currently being distributed
    uint256 public rewardAmount;

    // ============================ Constructor ====================================

    /// @notice Constructor of the `BaseStrategy`
    /// @param _poolManager Address of the `PoolManager` lending collateral to this strategy
    /// @param _rewards  The token given to reward keepers
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Address of the guardian
    constructor(
        address _poolManager,
        IERC20 _rewards,
        address[] memory governorList,
        address guardian
    ) {
        poolManager = IPoolManager(_poolManager);
        want = IERC20(poolManager.token());
        wantBase = 10**(IERC20Metadata(address(want)).decimals());
        require(guardian != address(0) && address(_rewards) != address(0), "0");
        // The token given as a reward to keepers should be different from the token handled by the
        // strategy
        require(address(_rewards) != address(want), "92");
        rewards = _rewards;

        // Initializing variables
        minReportDelay = 0;
        maxReportDelay = 86400;
        debtThreshold = 100 * BASE;
        minimumAmountMoved = 0;
        rewardAmount = 0;
        emergencyExit = false;

        // AccessControl
        // Governor is guardian so no need for a governor role
        // `PoolManager` is guardian as well to allow for more flexibility
        _setupRole(POOLMANAGER_ROLE, address(_poolManager));
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "0");
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }
        _setupRole(GUARDIAN_ROLE, guardian);
        _setRoleAdmin(POOLMANAGER_ROLE, POOLMANAGER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, POOLMANAGER_ROLE);

        // Give `PoolManager` unlimited access (might save gas)
        want.safeIncreaseAllowance(address(poolManager), type(uint256).max);
    }

    // ========================== Core functions ===================================

    /// @notice Harvests the Strategy, recognizing any profits or losses and adjusting
    /// the Strategy's position.
    /// @dev In the rare case the Strategy is in emergency shutdown, this will exit
    /// the Strategy's position.
    /// @dev  When `harvest()` is called, the Strategy reports to the Manager (via
    /// `poolManager.report()`), so in some cases `harvest()` must be called in order
    /// to take in profits, to borrow newly available funds from the Manager, or
    /// otherwise adjust its position. In other cases `harvest()` must be
    /// called to report to the Manager on the Strategy's position, especially if
    /// any losses have occurred.
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function harvest() external {
        uint256 profit = 0;
        uint256 loss = 0;
        uint256 debtOutstanding = poolManager.debtOutstanding();
        uint256 debtPayment = 0;
        if (emergencyExit) {
            // Free up as much capital as possible
            uint256 amountFreed = _liquidateAllPositions();
            if (amountFreed < debtOutstanding) {
                loss = debtOutstanding - amountFreed;
            } else if (amountFreed > debtOutstanding) {
                profit = amountFreed - debtOutstanding;
            }
            debtPayment = debtOutstanding - loss;
        } else {
            // Free up returns for Manager to pull
            (profit, loss, debtPayment) = _prepareReturn(debtOutstanding);
        }
        emit Harvested(profit, loss, debtPayment, debtOutstanding);

        // Taking into account the rewards to distribute
        // This should be done before reporting to the `PoolManager`
        // because the `PoolManager` will update the params.lastReport of the strategy
        if (rewardAmount > 0) {
            uint256 lastReport = poolManager.strategies(address(this)).lastReport;
            if (
                (block.timestamp - lastReport >= minReportDelay) && // Should not trigger if we haven't waited long enough since previous harvest
                ((block.timestamp - lastReport >= maxReportDelay) || // If hasn't been called in a while
                    (debtPayment > debtThreshold) || // If the debt was too high
                    (loss > 0) || // If some loss occured
                    (minimumAmountMoved < want.balanceOf(address(this)) + profit)) // If the amount moved was significant
            ) {
                rewards.safeTransfer(msg.sender, rewardAmount);
            }
        }

        // Allows Manager to take up to the "harvested" balance of this contract,
        // which is the amount it has earned since the last time it reported to
        // the Manager.
        poolManager.report(profit, loss, debtPayment);

        // Check if free returns are left, and re-invest them
        _adjustPosition();
    }

    /// @notice Withdraws `_amountNeeded` to `poolManager`.
    /// @param _amountNeeded How much `want` to withdraw.
    /// @return amountFreed How much `want` withdrawn.
    /// @return _loss Any realized losses
    /// @dev This may only be called by the `PoolManager`
    function withdraw(uint256 _amountNeeded)
        external
        onlyRole(POOLMANAGER_ROLE)
        returns (uint256 amountFreed, uint256 _loss)
    {
        // Liquidate as much as possible `want` (up to `_amountNeeded`)
        (amountFreed, _loss) = _liquidatePosition(_amountNeeded);
        // Send it directly back (NOTE: Using `msg.sender` saves some gas here)
        want.safeTransfer(msg.sender, amountFreed);
        // NOTE: Reinvest anything leftover on next `tend`/`harvest`
    }

    // ============================ View functions =================================

    /// @notice Provides an accurate estimate for the total amount of assets
    /// (principle + return) that this Strategy is currently managing,
    /// denominated in terms of `want` tokens.
    /// This total should be "realizable" e.g. the total value that could
    /// *actually* be obtained from this Strategy if it were to divest its
    /// entire position based on current on-chain conditions.
    /// @return The estimated total assets in this Strategy.
    /// @dev Care must be taken in using this function, since it relies on external
    /// systems, which could be manipulated by the attacker to give an inflated
    /// (or reduced) value produced by this function, based on current on-chain
    /// conditions (e.g. this function is possible to influence through
    /// flashloan attacks, oracle manipulations, or other DeFi attack
    /// mechanisms).
    function estimatedTotalAssets() public view virtual returns (uint256);

    /// @notice Provides an indication of whether this strategy is currently "active"
    /// in that it is managing an active position, or will manage a position in
    /// the future. This should correlate to `harvest()` activity, so that Harvest
    /// events can be tracked externally by indexing agents.
    /// @return True if the strategy is actively managing a position.
    function isActive() public view returns (bool) {
        return estimatedTotalAssets() > 0;
    }

    /// @notice Provides a signal to the keeper that `harvest()` should be called. The
    /// keeper will provide the estimated gas cost that they would pay to call
    /// `harvest()`, and this function should use that estimate to make a
    /// determination if calling it is "worth it" for the keeper. This is not
    /// the only consideration into issuing this trigger, for example if the
    /// position would be negatively affected if `harvest()` is not called
    /// shortly, then this can return `true` even if the keeper might be "at a
    /// loss"
    /// @return `true` if `harvest()` should be called, `false` otherwise.
    /// @dev `callCostInWei` must be priced in terms of `wei` (1e-18 ETH).
    /// @dev See `min/maxReportDelay`, `debtThreshold` to adjust the
    /// strategist-controlled parameters that will influence whether this call
    /// returns `true` or not. These parameters will be used in conjunction
    /// with the parameters reported to the Manager (see `params`) to determine
    /// if calling `harvest()` is merited.
    /// @dev This function has been tested in a branch different from the main branch
    function harvestTrigger() external view virtual returns (bool) {
        StrategyParams memory params = poolManager.strategies(address(this));

        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp - params.lastReport < minReportDelay) return false;

        // Should trigger if hasn't been called in a while
        if (block.timestamp - params.lastReport >= maxReportDelay) return true;

        // If some amount is owed, pay it back
        // NOTE: Since debt is based on deposits, it makes sense to guard against large
        //       changes to the value from triggering a harvest directly through user
        //       behavior. This should ensure reasonable resistance to manipulation
        //       from user-initiated withdrawals as the outstanding debt fluctuates.
        uint256 outstanding = poolManager.debtOutstanding();

        if (outstanding > debtThreshold) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();
        // Trigger if we have a loss to report

        if (total + debtThreshold < params.totalStrategyDebt) return true;

        uint256 profit = 0;
        if (total > params.totalStrategyDebt) profit = total - params.totalStrategyDebt; // We've earned a profit!

        // Otherwise, only trigger if it "makes sense" economically (gas cost
        // is <N% of value moved)
        uint256 credit = poolManager.creditAvailable();

        return (minimumAmountMoved < credit + profit);
    }

    // ============================ Internal Functions =============================

    /// @notice Performs any Strategy unwinding or other calls necessary to capture the
    /// "free return" this Strategy has generated since the last time its core
    /// position(s) were adjusted. Examples include unwrapping extra rewards.
    /// This call is only used during "normal operation" of a Strategy, and
    /// should be optimized to minimize losses as much as possible.
    ///
    /// This method returns any realized profits and/or realized losses
    /// incurred, and should return the total amounts of profits/losses/debt
    /// payments (in `want` tokens) for the Manager's accounting (e.g.
    /// `want.balanceOf(this) >= _debtPayment + _profit`).
    ///
    /// `_debtOutstanding` will be 0 if the Strategy is not past the configured
    /// debt limit, otherwise its value will be how far past the debt limit
    /// the Strategy is. The Strategy's debt limit is configured in the Manager.
    ///
    /// NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`.
    ///       It is okay for it to be less than `_debtOutstanding`, as that
    ///       should only used as a guide for how much is left to pay back.
    ///       Payments should be made to minimize loss from slippage, debt,
    ///       withdrawal fees, etc.
    ///
    /// See `poolManager.debtOutstanding()`.
    function _prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        );

    /// @notice Performs any adjustments to the core position(s) of this Strategy given
    /// what change the Manager made in the "investable capital" available to the
    /// Strategy. Note that all "free capital" in the Strategy after the report
    /// was made is available for reinvestment. Also note that this number
    /// could be 0, and you should handle that scenario accordingly.
    function _adjustPosition() internal virtual;

    /// @notice Liquidates up to `_amountNeeded` of `want` of this strategy's positions,
    /// irregardless of slippage. Any excess will be re-invested with `_adjustPosition()`.
    /// This function should return the amount of `want` tokens made available by the
    /// liquidation. If there is a difference between them, `_loss` indicates whether the
    /// difference is due to a realized loss, or if there is some other sitution at play
    /// (e.g. locked funds) where the amount made available is less than what is needed.
    ///
    /// NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    function _liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        returns (uint256 _liquidatedAmount, uint256 _loss);

    /// @notice Liquidates everything and returns the amount that got freed.
    /// This function is used during emergency exit instead of `_prepareReturn()` to
    /// liquidate all of the Strategy's positions back to the Manager.
    function _liquidateAllPositions() internal virtual returns (uint256 _amountFreed);

    /// @notice Override this to add all tokens/tokenized positions this contract
    /// manages on a *persistent* basis (e.g. not just for swapping back to
    /// want ephemerally).
    ///
    /// NOTE: Do *not* include `want`, already included in `sweep` below.
    ///
    /// Example:
    /// ```
    ///    function _protectedTokens() internal override view returns (address[] memory) {
    ///      address[] memory protected = new address[](3);
    ///      protected[0] = tokenA;
    ///      protected[1] = tokenB;
    ///      protected[2] = tokenC;
    ///      return protected;
    ///    }
    /// ```
    function _protectedTokens() internal view virtual returns (address[] memory);

    // ============================== Governance ===================================

    /// @notice Activates emergency exit. Once activated, the Strategy will exit its
    /// position upon the next harvest, depositing all funds into the Manager as
    /// quickly as is reasonable given on-chain conditions.
    /// @dev This may only be called by the `PoolManager`, because when calling this the `PoolManager` should at the same
    /// time update the debt ratio
    /// @dev This function can only be called once by the `PoolManager` contract
    /// @dev See `poolManager.setEmergencyExit()` and `harvest()` for further details.
    function setEmergencyExit() external onlyRole(POOLMANAGER_ROLE) {
        emergencyExit = true;
        emit EmergencyExitActivated();
    }

    /// @notice Used to change `rewards`.
    /// @param _rewards The address to use for pulling rewards.
    function setRewards(IERC20 _rewards) external onlyRole(GUARDIAN_ROLE) {
        require(address(_rewards) != address(0) && address(_rewards) != address(want), "92");
        rewards = _rewards;
        emit UpdatedRewards(address(_rewards));
    }

    /// @notice Used to change the reward amount and the `minimumAmountMoved` parameter
    /// @param _rewardAmount The new amount of reward given to keepers
    /// @param _minimumAmountMoved The new minimum amount of collateral moved for a call to `harvest` to be
    /// considered profitable and justifying a reward given to the keeper calling the function
    /// @dev A null reward amount corresponds to reward distribution being deactivated
    function setRewardAmountAndMinimumAmountMoved(uint256 _rewardAmount, uint256 _minimumAmountMoved)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        rewardAmount = _rewardAmount;
        minimumAmountMoved = _minimumAmountMoved;
        emit UpdatedRewardAmountAndMinimumAmountMoved(_rewardAmount, _minimumAmountMoved);
    }

    /// @notice Used to change `minReportDelay`. `minReportDelay` is the minimum number
    /// of blocks that should pass for `harvest()` to be called.
    /// @param _delay The minimum number of seconds to wait between harvests.
    /// @dev  For external keepers (such as the Keep3r network), this is the minimum
    /// time between jobs to wait. (see `harvestTrigger()`
    /// for more details.)
    function setMinReportDelay(uint256 _delay) external onlyRole(GUARDIAN_ROLE) {
        minReportDelay = _delay;
        emit UpdatedMinReportDelayed(_delay);
    }

    /// @notice Used to change `maxReportDelay`. `maxReportDelay` is the maximum number
    /// of blocks that should pass for `harvest()` to be called.
    /// @param _delay The maximum number of seconds to wait between harvests.
    /// @dev  For external keepers (such as the Keep3r network), this is the maximum
    /// time between jobs to wait. (see `harvestTrigger()`
    /// for more details.)
    function setMaxReportDelay(uint256 _delay) external onlyRole(GUARDIAN_ROLE) {
        maxReportDelay = _delay;
        emit UpdatedMaxReportDelayed(_delay);
    }

    /// @notice Sets how far the Strategy can go into loss without a harvest and report
    /// being required.
    /// @param _debtThreshold How big of a loss this Strategy may carry without
    /// @dev By default this is 0, meaning any losses would cause a harvest which
    /// will subsequently report the loss to the Manager for tracking. (See
    /// `harvestTrigger()` for more details.)
    function setDebtThreshold(uint256 _debtThreshold) external onlyRole(GUARDIAN_ROLE) {
        debtThreshold = _debtThreshold;
        emit UpdatedDebtThreshold(_debtThreshold);
    }

    /// @notice Removes tokens from this Strategy that are not the type of tokens
    /// managed by this Strategy. This may be used in case of accidentally
    /// sending the wrong kind of token to this Strategy.
    ///
    /// Tokens will be sent to `governance()`.
    ///
    /// This will fail if an attempt is made to sweep `want`, or any tokens
    /// that are protected by this Strategy.
    ///
    /// This may only be called by governance.
    /// @param _token The token to transfer out of this `PoolManager`.
    /// @param to Address to send the tokens to.
    /// @dev
    /// Implement `_protectedTokens()` to specify any additional tokens that
    /// should be protected from sweeping in addition to `want`.
    function sweep(address _token, address to) external onlyRole(GUARDIAN_ROLE) {
        require(_token != address(want), "93");

        address[] memory __protectedTokens = _protectedTokens();
        for (uint256 i = 0; i < __protectedTokens.length; i++)
            // In the strategy we use so far, the only protectedToken is the want token
            // and this has been checked above
            require(_token != __protectedTokens[i], "93");

        IERC20(_token).safeTransfer(to, IERC20(_token).balanceOf(address(this)));
    }

    // ============================ Manager functions ==============================

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    /// @dev This internal function has to be put in this file because Access Control is not defined
    /// in PoolManagerInternal
    function addGuardian(address _guardian) external virtual;

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function revokeGuardian(address guardian) external virtual;
}
