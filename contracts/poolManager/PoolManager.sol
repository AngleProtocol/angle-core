// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PoolManagerInternal.sol";

/// @title PoolManager
/// @author Angle Core Team
/// @notice The `PoolManager` contract corresponds to a collateral pool of the protocol for a stablecoin,
/// it manages a single ERC20 token. It is responsible for interacting with the strategies enabling the protocol
/// to get yield on its collateral
/// @dev This file contains the functions that are callable by governance or by other contracts of the protocol
/// @dev References to this contract are called `PoolManager`
contract PoolManager is PoolManagerInternal, IPoolManagerFunctions {
    using SafeERC20 for IERC20;

    // ============================ Constructor ====================================

    /// @notice Constructor of the `PoolManager` contract
    /// @param _token Address of the collateral
    /// @param _stableMaster Reference to the master stablecoin (`StableMaster`) interface
    function initialize(address _token, IStableMaster _stableMaster)
        external
        initializer
        zeroCheck(_token)
        zeroCheck(address(_stableMaster))
    {
        __AccessControl_init();

        // Creating the correct references
        stableMaster = _stableMaster;
        token = IERC20(_token);

        // Access Control
        // The roles in this contract can only be modified from the `StableMaster`
        // For the moment `StableMaster` never uses the `GOVERNOR_ROLE`
        _setupRole(STABLEMASTER_ROLE, address(stableMaster));
        _setRoleAdmin(STABLEMASTER_ROLE, STABLEMASTER_ROLE);
        _setRoleAdmin(GOVERNOR_ROLE, STABLEMASTER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, STABLEMASTER_ROLE);
        // No admin is set for `STRATEGY_ROLE`, checks are made in the appropriate functions
        // `addStrategy` and `revokeStrategy`
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // ========================= `StableMaster` Functions ==========================

    /// @notice Changes the references to contracts from this protocol with which this collateral `PoolManager` interacts
    /// and propagates some references to the `perpetualManager` and `feeManager` contracts
    /// @param governorList List of the governor addresses of protocol
    /// @param guardian Address of the guardian of the protocol (it can be revoked)
    /// @param _perpetualManager New reference to the `PerpetualManager` contract containing all the logic for HAs
    /// @param _feeManager Reference to the `FeeManager` contract that will serve for the `PerpetualManager` contract
    /// @param _oracle Reference to the `Oracle` contract that will serve for the `PerpetualManager` contract
    function deployCollateral(
        address[] memory governorList,
        address guardian,
        IPerpetualManager _perpetualManager,
        IFeeManager _feeManager,
        IOracle _oracle
    ) external override onlyRole(STABLEMASTER_ROLE) {
        // These references need to be stored to be able to propagate changes and maintain
        // the protocol's integrity when changes are posted from the `StableMaster`
        perpetualManager = _perpetualManager;
        feeManager = _feeManager;

        // Access control
        for (uint256 i = 0; i < governorList.length; i++) {
            _grantRole(GOVERNOR_ROLE, governorList[i]);
            _grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        _grantRole(GUARDIAN_ROLE, guardian);

        // Propagates the changes to the other involved contracts
        perpetualManager.deployCollateral(governorList, guardian, _feeManager, _oracle);
        _feeManager.deployCollateral(governorList, guardian, address(_perpetualManager));

        // `StableMaster` and `PerpetualManager` need to have approval to directly transfer some of
        // this contract's tokens
        token.safeIncreaseAllowance(address(stableMaster), type(uint256).max);
        token.safeIncreaseAllowance(address(_perpetualManager), type(uint256).max);
    }

    /// @notice Adds a new governor address and echoes it to other contracts
    /// @param _governor New governor address
    function addGovernor(address _governor) external override onlyRole(STABLEMASTER_ROLE) {
        // Access control for this contract
        _grantRole(GOVERNOR_ROLE, _governor);
        // Echoes the change to other contracts interacting with this collateral `PoolManager`
        // Since the other contracts interacting with this `PoolManager` do not have governor roles,
        // we just need it to set the new governor as guardian in these contracts
        _addGuardian(_governor);
    }

    /// @notice Removes a governor address and echoes it to other contracts
    /// @param _governor Governor address to remove
    function removeGovernor(address _governor) external override onlyRole(STABLEMASTER_ROLE) {
        // Access control for this contract
        _revokeRole(GOVERNOR_ROLE, _governor);
        _revokeGuardian(_governor);
    }

    /// @notice Changes the guardian address and echoes it to other contracts that interact with this `PoolManager`
    /// @param _guardian New guardian address
    /// @param guardian Old guardian address to revoke
    function setGuardian(address _guardian, address guardian) external override onlyRole(STABLEMASTER_ROLE) {
        _revokeGuardian(guardian);
        _addGuardian(_guardian);
    }

    /// @notice Revokes the guardian address and echoes the change to other contracts that interact with this `PoolManager`
    /// @param guardian Address of the guardian to revoke
    function revokeGuardian(address guardian) external override onlyRole(STABLEMASTER_ROLE) {
        _revokeGuardian(guardian);
    }

    /// @notice Allows to propagate the change of keeper for the collateral/stablecoin pair
    /// @param _feeManager New `FeeManager` contract
    function setFeeManager(IFeeManager _feeManager) external override onlyRole(STABLEMASTER_ROLE) {
        // Changing the reference in the `PerpetualManager` contract where keepers are involved
        feeManager = _feeManager;
        perpetualManager.setFeeManager(_feeManager);
    }

    // ============================= Yield Farming =================================

    /// @notice Provides an estimated Annual Percentage Rate for SLPs based on lending to other protocols
    /// @dev This function is an estimation and is made for external use only
    /// @dev This does not take into account transaction fees which accrue to SLPs too
    /// @dev This can be manipulated by a flash loan attack (SLP deposit/ withdraw) via `_getTotalAsset`
    /// when entering you should make sure this hasn't be called by a flash loan and look
    /// at a mean of past APR.
    function estimatedAPR() external view returns (uint256 apr) {
        apr = 0;
        (, ISanToken sanTokenForAPR, , , , uint256 sanRate, , SLPData memory slpData, ) = stableMaster.collateralMap(
            IPoolManager(address(this))
        );
        uint256 supply = sanTokenForAPR.totalSupply();

        // `sanRate` should never be equal to 0
        if (supply == 0) return type(uint256).max;

        for (uint256 i = 0; i < strategyList.length; i++) {
            apr =
                apr +
                (strategies[strategyList[i]].debtRatio * IStrategy(strategyList[i]).estimatedAPR()) /
                BASE_PARAMS;
        }
        apr = (apr * slpData.interestsForSLPs * _getTotalAsset()) / sanRate / supply;
    }

    /// @notice Tells a strategy how much it can borrow from this `PoolManager`
    /// @return Amount of token a strategy has access to as a credit line
    /// @dev Since this function is a view function, there is no need to have an access control logic
    /// even though it will just be relevant for a strategy
    /// @dev Manipulating `_getTotalAsset` with a flashloan will only
    /// result in tokens being transferred at the cost of the caller
    function creditAvailable() external view override returns (uint256) {
        StrategyParams storage params = strategies[msg.sender];

        uint256 target = (_getTotalAsset() * params.debtRatio) / BASE_PARAMS;

        if (target < params.totalStrategyDebt) return 0;

        return Math.min(target - params.totalStrategyDebt, _getBalance());
    }

    /// @notice Tells a strategy how much it owes to this `PoolManager`
    /// @return Amount of token a strategy has to reimburse
    /// @dev Manipulating `_getTotalAsset` with a flashloan will only
    /// result in tokens being transferred at the cost of the caller
    function debtOutstanding() external view override returns (uint256) {
        StrategyParams storage params = strategies[msg.sender];

        uint256 target = (_getTotalAsset() * params.debtRatio) / BASE_PARAMS;

        if (target > params.totalStrategyDebt) return 0;

        return (params.totalStrategyDebt - target);
    }

    /// @notice Reports the gains or loss made by a strategy
    /// @param gain Amount strategy has realized as a gain on its investment since its
    /// last report, and is free to be given back to `PoolManager` as earnings
    /// @param loss Amount strategy has realized as a loss on its investment since its
    /// last report, and should be accounted for on the `PoolManager`'s balance sheet.
    /// The loss will reduce the `debtRatio`. The next time the strategy will harvest,
    /// it will pay back the debt in an attempt to adjust to the new debt limit.
    /// @param debtPayment Amount strategy has made available to cover outstanding debt
    /// @dev This is the main contact point where the strategy interacts with the `PoolManager`
    /// @dev The strategy reports back what it has free, then the `PoolManager` contract "decides"
    /// whether to take some back or give it more. Note that the most it can
    /// take is `gain + _debtPayment`, and the most it can give is all of the
    /// remaining reserves. Anything outside of those bounds is abnormal behavior.
    function report(
        uint256 gain,
        uint256 loss,
        uint256 debtPayment
    ) external override onlyRole(STRATEGY_ROLE) {
        require(token.balanceOf(msg.sender) >= gain + debtPayment, "72");

        StrategyParams storage params = strategies[msg.sender];
        // Updating parameters in the `perpetualManager`
        // This needs to be done now because it has implications in `_getTotalAsset()`
        params.totalStrategyDebt = params.totalStrategyDebt + gain - loss;
        totalDebt = totalDebt + gain - loss;
        params.lastReport = block.timestamp;

        // Warning: `_getTotalAsset` could be manipulated by flashloan attacks.
        // It may allow external users to transfer funds into strategy or remove funds
        // from the strategy. Yet, as it does not impact the profit or loss and as attackers
        // have no interest in making such txs to have a direct profit, we let it as is.
        // The only issue is if the strategy is compromised; in this case governance
        // should revoke the strategy
        uint256 target = ((_getTotalAsset()) * params.debtRatio) / BASE_PARAMS;
        if (target > params.totalStrategyDebt) {
            // If the strategy has some credit left, tokens can be transferred to this strategy
            uint256 available = Math.min(target - params.totalStrategyDebt, _getBalance());
            params.totalStrategyDebt = params.totalStrategyDebt + available;
            totalDebt = totalDebt + available;
            if (available > 0) {
                token.safeTransfer(msg.sender, available);
            }
        } else {
            uint256 available = Math.min(params.totalStrategyDebt - target, debtPayment + gain);
            params.totalStrategyDebt = params.totalStrategyDebt - available;
            totalDebt = totalDebt - available;
            if (available > 0) {
                token.safeTransferFrom(msg.sender, address(this), available);
            }
        }
        emit StrategyReported(msg.sender, gain, loss, debtPayment, params.totalStrategyDebt);

        // Handle gains before losses
        if (gain > 0) {
            uint256 gainForSurplus = (gain * interestsForSurplus) / BASE_PARAMS;
            uint256 adminDebtPre = adminDebt;
            // Depending on the current admin debt distribute the necessary gain from the strategies
            if (adminDebtPre == 0) interestsAccumulated += gainForSurplus;
            else if (adminDebtPre <= gainForSurplus) {
                interestsAccumulated += gainForSurplus - adminDebtPre;
                adminDebt = 0;
            } else adminDebt -= gainForSurplus;
            stableMaster.accumulateInterest(gain - gainForSurplus);
            emit FeesDistributed(gain);
        }

        // Handle eventual losses
        if (loss > 0) {
            uint256 lossForSurplus = (loss * interestsForSurplus) / BASE_PARAMS;
            uint256 interestsAccumulatedPreLoss = interestsAccumulated;
            // If the loss can not be entirely soaked by the interests to be distributed then
            // the protocol keeps track of the debt
            if (lossForSurplus > interestsAccumulatedPreLoss) {
                interestsAccumulated = 0;
                adminDebt += lossForSurplus - interestsAccumulatedPreLoss;
            } else interestsAccumulated -= lossForSurplus;
            // The rest is incurred to SLPs
            stableMaster.signalLoss(loss - lossForSurplus);
        }
    }

    // =========================== Governor Functions ==============================

    /// @notice Allows to recover any ERC20 token, including the token handled by this contract, and to send it
    /// to a contract
    /// @param tokenAddress Address of the token to recover
    /// @param to Address of the contract to send collateral to
    /// @param amountToRecover Amount of collateral to transfer
    /// @dev As this function can be used to transfer funds to another contract, it has to be a `GOVERNOR` function
    /// @dev In case the concerned token is the specific token handled by this contract, this function checks that the
    /// amount entered is not too big and approximates the surplus of the protocol
    /// @dev To esimate the amount of user claims on the concerned collateral, this function uses the `stocksUsers` for
    /// this collateral, but this is just an approximation as users can claim the collateral of their choice provided
    /// that they own a stablecoin
    /// @dev The sanity check excludes the HA claims: to get a sense of it, this function would need to compute the cash out
    /// amount of all the perpetuals, and this cannot be done on-chain in a cheap manner
    /// @dev Overall, even though there is a sanity check, this function relies on the fact that governance is not corrupted
    /// in this protocol and will not try to withdraw too much funds
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amountToRecover
    ) external onlyRole(GOVERNOR_ROLE) {
        if (tokenAddress == address(token)) {
            // Fetching info from the `StableMaster`
            (
                ,
                ISanToken sanToken,
                ,
                IOracle oracle,
                uint256 stocksUsers,
                uint256 sanRate,
                uint256 collatBase,
                ,

            ) = IStableMaster(stableMaster).collateralMap(IPoolManager(address(this)));

            // Checking if there are enough reserves for the amount to withdraw
            require(
                _getTotalAsset() >=
                    amountToRecover +
                        (sanToken.totalSupply() * sanRate) /
                        BASE_TOKENS +
                        (stocksUsers * collatBase) /
                        oracle.readUpper() +
                        interestsAccumulated,
                "66"
            );

            token.safeTransfer(to, amountToRecover);
        } else {
            IERC20(tokenAddress).safeTransfer(to, amountToRecover);
        }
        emit Recovered(tokenAddress, to, amountToRecover);
    }

    /// @notice Adds a strategy to the `PoolManager`
    /// @param strategy The address of the strategy to add
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev Multiple checks are made. For instance, the contract must not already belong to the `PoolManager`
    /// and the underlying token of the strategy has to be consistent with the `PoolManager` contracts
    /// @dev This function is a `governor` function and not a `guardian` one because a `guardian` could add a strategy
    /// enabling the withdraw of the funds of the protocol
    /// @dev The `_debtRatio` should be expressed in `BASE_PARAMS`
    function addStrategy(address strategy, uint256 _debtRatio) external onlyRole(GOVERNOR_ROLE) zeroCheck(strategy) {
        StrategyParams storage params = strategies[strategy];

        require(params.lastReport == 0, "73");
        require(address(this) == IStrategy(strategy).poolManager(), "74");
        // Using current code, this condition should always be verified as in the constructor
        // of the strategy the `want()` is set to the token of this `PoolManager`
        require(address(token) == IStrategy(strategy).want(), "75");
        require(debtRatio + _debtRatio <= BASE_PARAMS, "76");

        // Add strategy to approved strategies
        params.lastReport = 1;
        params.totalStrategyDebt = 0;
        params.debtRatio = _debtRatio;

        _grantRole(STRATEGY_ROLE, strategy);

        // Update global parameters
        debtRatio += _debtRatio;
        emit StrategyAdded(strategy, debtRatio);

        strategyList.push(strategy);
    }

    // =========================== Guardian Functions ==============================

    /// @notice Sets a new surplus distributor to which surplus from the protocol will be pushed
    /// @param newSurplusConverter Address to which the role needs to be granted
    /// @dev It is as if the `GUARDIAN_ROLE` was admin of the `SURPLUS_DISTRIBUTOR_ROLE`
    /// @dev The address can be the zero address in case the protocol revokes the `surplusConverter`
    function setSurplusConverter(address newSurplusConverter) external onlyRole(GUARDIAN_ROLE) {
        address oldSurplusConverter = surplusConverter;
        surplusConverter = newSurplusConverter;
        emit SurplusConverterUpdated(newSurplusConverter, oldSurplusConverter);
    }

    /// @notice Sets the share of the interests going directly to the surplus
    /// @param _interestsForSurplus New value of the interests going directly to the surplus for buybacks
    /// @dev Guardian should make sure the incentives for SLPs are still high enough for them to enter the protocol
    function setInterestsForSurplus(uint64 _interestsForSurplus)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_interestsForSurplus)
    {
        interestsForSurplus = _interestsForSurplus;
        emit InterestsForSurplusUpdated(_interestsForSurplus);
    }

    /// @notice Modifies the funds a strategy has access to
    /// @param strategy The address of the Strategy
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev The update has to be such that the `debtRatio` does not exceeds the 100% threshold
    /// as this `PoolManager` cannot lend collateral that it doesn't not own.
    /// @dev `_debtRatio` is stored as a uint256 but as any parameter of the protocol, it should be expressed
    /// in `BASE_PARAMS`
    function updateStrategyDebtRatio(address strategy, uint256 _debtRatio) external onlyRole(GUARDIAN_ROLE) {
        _updateStrategyDebtRatio(strategy, _debtRatio);
    }

    /// @notice Triggers an emergency exit for a strategy and then harvests it to fetch all the funds
    /// @param strategy The address of the `Strategy`
    function setStrategyEmergencyExit(address strategy) external onlyRole(GUARDIAN_ROLE) {
        _updateStrategyDebtRatio(strategy, 0);
        IStrategy(strategy).setEmergencyExit();
        IStrategy(strategy).harvest();
    }

    /// @notice Revokes a strategy
    /// @param strategy The address of the strategy to revoke
    /// @dev This should only be called after the following happened in order: the `strategy.debtRatio` has been set to 0,
    /// `harvest` has been called enough times to recover all capital gain/losses.
    function revokeStrategy(address strategy) external onlyRole(GUARDIAN_ROLE) {
        StrategyParams storage params = strategies[strategy];

        require(params.debtRatio == 0, "77");
        require(params.totalStrategyDebt == 0, "77");
        uint256 strategyListLength = strategyList.length;
        require(params.lastReport != 0 && strategyListLength >= 1, "78");
        // It has already been checked whether the strategy was a valid strategy
        for (uint256 i = 0; i < strategyListLength - 1; i++) {
            if (strategyList[i] == strategy) {
                strategyList[i] = strategyList[strategyListLength - 1];
                break;
            }
        }

        strategyList.pop();

        // Update global parameters
        debtRatio -= params.debtRatio;
        delete strategies[strategy];

        _revokeRole(STRATEGY_ROLE, strategy);

        emit StrategyRevoked(strategy);
    }

    /// @notice Withdraws a given amount from a strategy
    /// @param strategy The address of the strategy
    /// @param amount The amount to withdraw
    /// @dev This function tries to recover `amount` from the strategy, but it may not go through
    /// as we may not be able to withdraw from the lending protocol the full amount
    /// @dev In this last case we only update the parameters by setting the loss as the gap between
    /// what has been asked and what has been returned.
    function withdrawFromStrategy(IStrategy strategy, uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        StrategyParams storage params = strategies[address(strategy)];
        require(params.lastReport != 0, "78");

        uint256 loss;
        (amount, loss) = strategy.withdraw(amount);

        // Handling eventual losses
        params.totalStrategyDebt = params.totalStrategyDebt - loss - amount;
        totalDebt = totalDebt - loss - amount;

        emit StrategyReported(address(strategy), 0, loss, amount - loss, params.totalStrategyDebt);

        // Handle eventual losses
        // With the strategy we are using in current tests, it is going to be impossible to have
        // a positive loss by calling strategy.withdraw, this function indeed calls _liquidatePosition
        // which output value is always zero
        if (loss > 0) stableMaster.signalLoss(loss);
    }

    // =================== Surplus Distributor Function ============================

    /// @notice Allows to push interests revenue accumulated by the protocol to the `surplusConverter` to do buybacks
    ///  or another form of redistribution to ANGLE or veANGLE token holders
    /// @dev This function is permissionless and anyone can transfer the `interestsAccumulated` by the protocol
    /// to the `surplusConverter`
    function pushSurplus() external {
        // If the `surplusConverter` has not been initialized, surplus should not be distributed
        // Storing the `surplusConverter` in an intermediate variable to avoid multiple reads in
        // storage
        address surplusConverterMem = surplusConverter;
        require(surplusConverterMem != address(0), "0");
        uint256 amount = interestsAccumulated;
        interestsAccumulated = 0;
        // Storing the `token` in memory to avoid duplicate reads in storage
        IERC20 tokenMem = token;
        tokenMem.safeTransfer(surplusConverterMem, amount);
        emit Recovered(address(tokenMem), surplusConverterMem, amount);
    }

    // ======================== Getters - View Functions ===========================

    /// @notice Gets the current balance of this `PoolManager` contract
    /// @return The amount of the underlying collateral that the contract currently owns
    /// @dev This balance does not take into account what has been lent to strategies
    function getBalance() external view override returns (uint256) {
        return _getBalance();
    }

    /// @notice Gets the total amount of collateral that is controlled by this `PoolManager` contract
    /// @return The amount of collateral owned by this contract plus the amount that has been lent to strategies
    /// @dev This is the value that is used to compute the debt ratio for a given strategy
    function getTotalAsset() external view override returns (uint256) {
        return _getTotalAsset();
    }
}
