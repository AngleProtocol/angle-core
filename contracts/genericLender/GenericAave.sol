// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/external/uniswap/IUniswapRouter.sol";
import "../interfaces/external/aave/IAave.sol";

import "./GenericLenderBase.sol";

struct AaveReferences {
    IAToken aToken;
    IProtocolDataProvider protocolDataProvider;
    IStakedAave stkAave;
    address aave;
}

/// @title GenericAave
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat/blob/master/contracts/GenericLender/GenericAave.sol
/// @notice A contract to lend any ERC20 to Aave
/// @dev This contract is already in production, see at 0x71bE8726C96873F04d2690AA05b2ACcA7C7104d0 or there: https://etherscan.io/address/0xb164c0f42d9C6DBf976b60962fFe790A35e42b13#code
contract GenericAave is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;

    event PathUpdated(bytes _path);
    event IncentivisedUpdated(bool _isIncentivised);
    event CustomReferralUpdated(uint16 customReferral);

    uint256 internal constant _SECONDS_IN_YEAR = 365 days;
    uint16 internal constant _DEFAULT_REFERRAL = 179; // jmonteer's referral code

    // ==================== References to contracts =============================
    address public constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IAToken public immutable aToken;
    IProtocolDataProvider public immutable protocolDataProvider;
    IStakedAave public immutable stkAave;
    address public immutable aave;
    IUniswapV3Router public immutable uniswapV3Router;
    // Used to get the `want` price of the AAVE token
    IUniswapV2Router public immutable uniswapV2Router;

    // ==================== Parameters =============================

    bytes public path;
    bool public isIncentivised;
    uint16 internal _customReferral;

    // ============================= Constructor =============================

    /// @param _path Bytes to encode the swap from aave to want
    constructor(
        address _strategy,
        string memory name,
        IUniswapV3Router _uniswapV3Router,
        IUniswapV2Router _uniswapV2Router,
        AaveReferences memory aaveReferences,
        bool _isIncentivised,
        bytes memory _path,
        address[] memory governorList,
        address guardian
    ) GenericLenderBase(_strategy, name, governorList, guardian) {
        // This transaction is going to revert if `_strategy`, `aave`, `protocolDataProvider` or `aToken`
        // are equal to the zero address
        require(
            address(_uniswapV2Router) != address(0) &&
                address(_uniswapV3Router) != address(0) &&
                address(aaveReferences.stkAave) != address(0),
            "0"
        );
        require(
            !_isIncentivised || address(aaveReferences.aToken.getIncentivesController()) != address(0),
            "aToken does not have incentives controller set up"
        );
        uniswapV3Router = _uniswapV3Router;
        uniswapV2Router = _uniswapV2Router;
        aToken = aaveReferences.aToken;
        protocolDataProvider = aaveReferences.protocolDataProvider;
        stkAave = aaveReferences.stkAave;
        aave = aaveReferences.aave;
        isIncentivised = _isIncentivised;
        path = _path;
        ILendingPool lendingPool = ILendingPool(
            aaveReferences.protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool()
        );
        // We cannot store a `lendingPool` variable here otherwise we would get a stack too deep problem
        require(
            lendingPool.getReserveData(address(want)).aTokenAddress == address(aaveReferences.aToken),
            "wrong aToken"
        );
        IERC20(address(want)).safeApprove(address(lendingPool), type(uint256).max);
        // Approving the Uniswap router for the transactions
        IERC20(aaveReferences.aave).safeApprove(address(_uniswapV3Router), type(uint256).max);
    }

    // ============================= External Functions =============================

    /// @notice Deposits the current balance to the lending platform
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        _deposit(balance);
    }

    /// @notice Withdraws a given amount from lender
    /// @param amount Amount to withdraw
    /// @return Amount actually withdrawn
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @notice Withdraws as much as possible in case of emergency and sends it to the `PoolManager`
    /// @param amount Amount to withdraw
    /// @dev Does not check if any error occurs or if the amount withdrawn is correct
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        _lendingPool().withdraw(address(want), amount, address(this));

        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    /// @notice Withdraws as much as possible
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function startCooldown() external onlyRole(GUARDIAN_ROLE) {
        // for emergency cases
        IStakedAave(stkAave).cooldown(); // it will revert if balance of stkAave == 0
    }

    /// @notice Trigger to claim rewards once every 10 days
    /// Only callable if the token is incentivised by Aave Governance (_checkCooldown returns true)
    /// @dev Only for incentivised aTokens
    function harvest() external {
        require(_checkCooldown(), "conditions are not met");
        // redeem AAVE from stkAave
        uint256 stkAaveBalance = IERC20(address(stkAave)).balanceOf(address(this));
        if (stkAaveBalance > 0) {
            stkAave.redeem(address(this), stkAaveBalance);
        }

        // sell AAVE for want
        uint256 aaveBalance = IERC20(aave).balanceOf(address(this));
        _sellAAVEForWant(aaveBalance);

        // deposit want in lending protocol
        uint256 balance = want.balanceOf(address(this));
        if (balance > 0) {
            _deposit(balance);
        }

        // claim rewards
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        uint256 pendingRewards = _incentivesController().getRewardsBalance(assets, address(this));
        if (pendingRewards > 0) {
            _incentivesController().claimRewards(assets, pendingRewards, address(this));
        }

        // request start of cooldown period
        if (IERC20(address(stkAave)).balanceOf(address(this)) > 0) {
            stkAave.cooldown();
        }
    }

    // ============================= External View Functions =============================

    /// @notice Returns the current total of assets managed
    function nav() external view override returns (uint256) {
        return _nav();
    }

    /// @notice Returns the current balance of aTokens
    function underlyingBalanceStored() public view returns (uint256 balance) {
        balance = aToken.balanceOf(address(this));
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate
    function apr() external view override returns (uint256) {
        return _apr();
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate weighted by a factor
    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a * _nav();
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate after a new deposit
    /// @param extraAmount The amount to add to the lending platform
    function aprAfterDeposit(uint256 extraAmount) external view override returns (uint256) {
        // i need to calculate new supplyRate after Deposit (when deposit has not been done yet)
        DataTypes.ReserveData memory reserveData = _lendingPool().getReserveData(address(want));

        (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            ,
            ,
            ,
            uint256 averageStableBorrowRate,
            ,
            ,

        ) = protocolDataProvider.getReserveData(address(want));

        uint256 newLiquidity = availableLiquidity + extraAmount;

        (, , , , uint256 reserveFactor, , , , , ) = protocolDataProvider.getReserveConfigurationData(address(want));

        (uint256 newLiquidityRate, , ) = IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress)
            .calculateInterestRates(
                address(want),
                newLiquidity,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor
            );
        uint256 incentivesRate = _incentivesRate(newLiquidity + totalStableDebt + totalVariableDebt); // total supplied liquidity in Aave v2

        return newLiquidityRate / 1e9 + incentivesRate; // divided by 1e9 to go from Ray to Wad
    }

    /// @notice Checks if assets are currently managed by this contract
    function hasAssets() external view override returns (bool) {
        return aToken.balanceOf(address(this)) > 0;
    }

    /// @notice Checks if harvest is callable
    function harvestTrigger() external view returns (bool) {
        return _checkCooldown();
    }

    // ============================= Internal Functions =============================

    /// @notice See `apr`
    function _apr() internal view returns (uint256) {
        uint256 liquidityRate = uint256(_lendingPool().getReserveData(address(want)).currentLiquidityRate) / 1e9; // dividing by 1e9 to pass from ray to wad
        (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = protocolDataProvider.getReserveData(address(want));
        uint256 incentivesRate = _incentivesRate(availableLiquidity + totalStableDebt + totalVariableDebt); // total supplied liquidity in Aave v2
        return liquidityRate + incentivesRate;
    }

    /// @notice See `nav`
    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)) + underlyingBalanceStored();
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = aToken.balanceOf(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying + looseBalance;

        if (amount > total) {
            //cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        //not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(aToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;

            if (toWithdraw <= liquidity) {
                //we can take all
                _lendingPool().withdraw(address(want), toWithdraw, address(this));
            } else {
                //take all we can
                _lendingPool().withdraw(address(want), liquidity, address(this));
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /// @notice See `deposit`
    function _deposit(uint256 amount) internal {
        ILendingPool lp = _lendingPool();
        // NOTE: Checks if allowance is enough and acts accordingly
        // allowance might not be enough if
        //     i) initial allowance has been used (should take years)
        //     ii) lendingPool contract address has changed (Aave updated the contract address)
        if (want.allowance(address(this), address(lp)) < amount) {
            IERC20(address(want)).safeApprove(address(lp), 0);
            IERC20(address(want)).safeApprove(address(lp), type(uint256).max);
        }

        uint16 referral;
        uint16 __customReferral = _customReferral;
        if (__customReferral != 0) {
            referral = __customReferral;
        } else {
            referral = _DEFAULT_REFERRAL;
        }

        lp.deposit(address(want), amount, address(this), referral);
    }

    /// @notice Returns address of lending pool from Aave's address provider
    function _lendingPool() internal view returns (ILendingPool lendingPool) {
        lendingPool = ILendingPool(protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool());
    }

    /// @notice Checks if there is a need for calling harvest
    function _checkCooldown() internal view returns (bool) {
        if (!isIncentivised) {
            return false;
        }

        uint256 cooldownStartTimestamp = IStakedAave(stkAave).stakersCooldowns(address(this));
        uint256 cooldownSeconds = IStakedAave(stkAave).COOLDOWN_SECONDS();
        uint256 unstakeWindow = IStakedAave(stkAave).UNSTAKE_WINDOW();
        if (block.timestamp >= cooldownStartTimestamp + cooldownSeconds) {
            return
                block.timestamp - cooldownStartTimestamp + cooldownSeconds <= unstakeWindow ||
                cooldownStartTimestamp == 0;
        } else {
            return false;
        }
    }

    /// @notice Calculates APR from Liquidity Mining Program
    /// @param totalLiquidity Total liquidity available in the pool
    /// @dev At Angle, compared with Yearn implementation, we have decided to add a check
    /// about the `totalLiquidity` before entering the `if` branch
    function _incentivesRate(uint256 totalLiquidity) internal view returns (uint256) {
        // only returns != 0 if the incentives are in place at the moment.
        // it will fail if the isIncentivised is set to true but there is no incentives
        IAaveIncentivesController incentivesController = _incentivesController();
        if (isIncentivised && block.timestamp < incentivesController.getDistributionEnd() && totalLiquidity > 0) {
            uint256 _emissionsPerSecond;
            (, _emissionsPerSecond, ) = _incentivesController().getAssetData(address(aToken));
            if (_emissionsPerSecond > 0) {
                uint256 emissionsInWant = _AAVEtoWant(_emissionsPerSecond); // amount of emissions in want

                uint256 incentivesRate = (emissionsInWant * _SECONDS_IN_YEAR * 1e18) / totalLiquidity; // APRs are in 1e18

                return (incentivesRate * 9500) / 10000; // 95% of estimated APR to avoid overestimations
            }
        }
        return 0;
    }

    /// @notice Estimates the value of `_amount` AAVE tokens
    /// @param _amount Amount of AAVE to compute the `want` price of
    /// @dev This function uses a UniswapV2 oracle to easily compute the price (which is not feasible
    /// with UniswapV3)
    ///@dev When entering this function, it has been checked that the `amount` parameter is not null
    // solhint-disable-next-line func-name-mixedcase
    function _AAVEtoWant(uint256 _amount) internal view returns (uint256) {
        // We use a different path when trying to get the price of the AAVE in `want`
        address[] memory pathPrice;

        if (address(want) == address(WETH)) {
            pathPrice = new address[](2);
            pathPrice[0] = address(aave);
            pathPrice[1] = address(want);
        } else {
            pathPrice = new address[](3);
            pathPrice[0] = address(aave);
            pathPrice[1] = address(WETH);
            pathPrice[2] = address(want);
        }

        uint256[] memory amounts = uniswapV2Router.getAmountsOut(_amount, pathPrice);
        return amounts[amounts.length - 1];
    }

    /// @notice Swaps an amount from `AAVE` to Want
    /// @param _amount The amount to convert
    function _sellAAVEForWant(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        if (IERC20(aave).allowance(address(this), address(uniswapV3Router)) < _amount) {
            IERC20(aave).safeApprove(address(uniswapV3Router), 0);
            IERC20(aave).safeApprove(address(uniswapV3Router), type(uint256).max);
        }

        uniswapV3Router.exactInput(ExactInputParams(path, address(this), block.timestamp, _amount, uint256(0)));
    }

    /// @notice Returns the incentive controller
    function _incentivesController() internal view returns (IAaveIncentivesController) {
        if (isIncentivised) {
            return aToken.getIncentivesController();
        } else {
            return IAaveIncentivesController(address(0));
        }
    }

    /// @notice Specifies the token managed by this contract during normal operation
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(aToken);
        return protected;
    }

    // ============================= Governance =============================

    /// @notice For the management to activate / deactivate incentives functionality
    /// @param _isIncentivised Boolean for activation
    function setIsIncentivised(bool _isIncentivised) external onlyRole(GUARDIAN_ROLE) {
        // NOTE: if the aToken is not incentivised, `getIncentivesController()` might revert (aToken won't implement it)
        // to avoid calling it, we use the OR and lazy evaluation
        require(
            !_isIncentivised || address(aToken.getIncentivesController()) != address(0),
            "aToken does not have incentives controller set up"
        );
        isIncentivised = _isIncentivised;
        emit IncentivisedUpdated(_isIncentivised);
    }

    /// @notice Sets the referral
    /// @param __customReferral New custom referral
    function setReferralCode(uint16 __customReferral) external onlyRole(GUARDIAN_ROLE) {
        require(__customReferral != 0, "invalid referral code");
        _customReferral = __customReferral;
        emit CustomReferralUpdated(_customReferral);
    }

    /// @notice Sets the path for swap of AAVE to `want`
    /// @param _path New path
    function setPath(bytes memory _path) external onlyRole(GUARDIAN_ROLE) {
        path = _path;
        emit PathUpdated(_path);
    }
}
