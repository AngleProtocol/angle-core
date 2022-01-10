// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/external/compound/CErc20I.sol";
import "../interfaces/external/compound/IComptroller.sol";
import "../interfaces/external/compound/InterestRateModel.sol";
import "../interfaces/external/uniswap/IUniswapRouter.sol";

import "./GenericLenderBase.sol";

/// @title GenericCompound
/// @author Forker from here: https://github.com/Grandthrax/yearnV2-generic-lender-strat/blob/master/contracts/GenericLender/GenericCompound.sol
/// @notice A contract to lend any ERC20 to Compound
contract GenericCompound is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;

    event PathUpdated(bytes _path);

    uint256 public constant BLOCKS_PER_YEAR = 2_350_000;

    // ==================== References to contracts =============================

    CErc20I public immutable cToken;
    address public immutable comp;
    IComptroller public immutable comptroller;
    IUniswapV3Router public immutable uniswapV3Router;
    // Used to get the `want` price of the AAVE token
    IUniswapV2Router public immutable uniswapV2Router;

    address public constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // ==================== Parameters =============================

    bytes public path;
    uint256 public minCompToSell = 0.5 ether;

    // ============================= Constructor =============================

    /// @notice Constructor of the `GenericCompound`
    /// @param _strategy Reference to the strategy using this lender
    /// @param _path Bytes to encode the swap from `comp` to `want`
    /// @param _cToken Address of the cToken
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    constructor(
        address _strategy,
        string memory name,
        IUniswapV3Router _uniswapV3Router,
        IUniswapV2Router _uniswapV2Router,
        IComptroller _comptroller,
        address _comp,
        bytes memory _path,
        address _cToken,
        address[] memory governorList,
        address guardian
    ) GenericLenderBase(_strategy, name, governorList, guardian) {
        // This transaction is going to revert if `_strategy`, `_comp` or `_cToken` are equal to the zero address
        require(
            address(_uniswapV2Router) != address(0) &&
                address(_uniswapV3Router) != address(0) &&
                address(_comptroller) != address(0),
            "0"
        );
        path = _path;
        uniswapV3Router = _uniswapV3Router;
        uniswapV2Router = _uniswapV2Router;
        comptroller = _comptroller;
        comp = _comp;
        cToken = CErc20I(_cToken);
        require(CErc20I(_cToken).underlying() == address(want), "wrong cToken");
        want.safeApprove(_cToken, type(uint256).max);
        IERC20(_comp).safeApprove(address(_uniswapV3Router), type(uint256).max);
    }

    // ===================== External Strategy Functions ===========================

    /// @notice Deposits the current balance of the contract to the lending platform
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        require(cToken.mint(balance) == 0, "mint fail");
    }

    /// @notice Withdraws a given amount from lender
    /// @param amount The amount the caller wants to withdraw
    /// @return Amount actually withdrawn
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @notice Withdraws as much as possible from the lending platform
    /// @return Whether everything was withdrawn or not
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    // ============================= External View Functions =============================

    /// @notice Helper function to get the current total of assets managed by the lender.
    function nav() external view override returns (uint256) {
        return _nav();
    }

    /// @notice Helper function the current balance of cTokens
    function underlyingBalanceStored() public view returns (uint256 balance) {
        uint256 currentCr = cToken.balanceOf(address(this));
        if (currentCr == 0) {
            balance = 0;
        } else {
            //The current exchange rate as an unsigned integer, scaled by 1e18.
            balance = (currentCr * cToken.exchangeRateStored()) / 1e18;
        }
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
    /// of `amount`
    /// @param amount Amount to add to the lending platform, and that we want to take into account
    /// in the apr computation
    function aprAfterDeposit(uint256 amount) external view override returns (uint256) {
        uint256 cashPrior = want.balanceOf(address(cToken));

        uint256 borrows = cToken.totalBorrows();

        uint256 reserves = cToken.totalReserves();

        uint256 reserverFactor = cToken.reserveFactorMantissa();

        InterestRateModel model = cToken.interestRateModel();

        // The supply rate is derived from the borrow rate, reserve factor and the amount of total borrows.
        uint256 supplyRate = model.getSupplyRate(cashPrior + amount, borrows, reserves, reserverFactor);
        // Adding the yield from comp
        return supplyRate * BLOCKS_PER_YEAR + _incentivesRate(amount);
    }

    /// @notice Check if assets are currently managed by this contract
    function hasAssets() external view override returns (bool) {
        return cToken.balanceOf(address(this)) > 0 || want.balanceOf(address(this)) > 0;
    }

    // ============================= Governance =============================

    /// @notice Sets the path for the swap of `comp` tokens
    /// @param _path New path
    function setPath(bytes memory _path) external onlyRole(GUARDIAN_ROLE) {
        path = _path;
        emit PathUpdated(_path);
    }

    /// @notice Withdraws as much as possible in case of emergency and sends it to the `PoolManager`
    /// @param amount Amount to withdraw
    /// @dev Does not check if any error occurs or if the amount withdrawn is correct
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        // Do not care about errors here, what is important is to withdraw what is possible
        cToken.redeemUnderlying(amount);

        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    // ============================= Internal Functions =============================

    /// @notice See `apr`
    function _apr() internal view returns (uint256) {
        return cToken.supplyRatePerBlock() * BLOCKS_PER_YEAR + _incentivesRate(0);
    }

    /// @notice See `nav`
    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)) + underlyingBalanceStored();
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = cToken.balanceOfUnderlying(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying + looseBalance;

        if (amount > total) {
            // Can't withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        // Not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(cToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;

            if (toWithdraw <= liquidity) {
                // We can take all
                require(cToken.redeemUnderlying(toWithdraw) == 0, "redeemUnderlying fail");
            } else {
                // Take all we can
                require(cToken.redeemUnderlying(liquidity) == 0, "redeemUnderlying fail");
            }
        }
        _disposeOfComp();
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /// @notice Claims and swaps from Uniswap the `comp` earned
    function _disposeOfComp() internal {
        address[] memory holders = new address[](1);
        CTokenI[] memory cTokens = new CTokenI[](1);
        holders[0] = address(this);
        cTokens[0] = CTokenI(address(cToken));
        comptroller.claimComp(holders, cTokens, false, true);
        uint256 _comp = IERC20(comp).balanceOf(address(this));

        if (_comp > minCompToSell) {
            uniswapV3Router.exactInput(ExactInputParams(path, address(this), block.timestamp, _comp, uint256(0)));
        }
    }

    /// @notice Calculates APR from Compound's Liquidity Mining Program
    /// @param amountToAdd Amount to add to the `totalSupplyInWant` (for the `aprAfterDeposit` function)
    function _incentivesRate(uint256 amountToAdd) internal view returns (uint256) {
        uint256 supplySpeed = comptroller.compSupplySpeeds(address(cToken));
        uint256 totalSupplyInWant = (cToken.totalSupply() * cToken.exchangeRateStored()) / 1e18 + amountToAdd;
        // `supplySpeed` is in `COMP` unit -> the following operation is going to put it in `want` unit
        supplySpeed = _comptoWant(supplySpeed);
        uint256 incentivesRate;
        // Added for testing purposes and to handle the edge case where there is nothing left in a market
        if (totalSupplyInWant == 0) {
            incentivesRate = supplySpeed * BLOCKS_PER_YEAR;
        } else {
            // `incentivesRate` is expressed in base 18 like all APR
            incentivesRate = (supplySpeed * BLOCKS_PER_YEAR * 1e18) / totalSupplyInWant;
        }
        return (incentivesRate * 9500) / 10000; // 95% of estimated APR to avoid overestimations
    }

    /// @notice Estimates the value of `_amount` AAVE tokens
    /// @param _amount Amount of comp to compute the `want` price of
    /// @dev This function uses a UniswapV2 oracle to easily compute the price (which is not feasible
    /// with UniswapV3)
    function _comptoWant(uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        // We use a different path when trying to get the price of the AAVE in `want`
        address[] memory pathPrice;

        if (address(want) == address(WETH)) {
            pathPrice = new address[](2);
            pathPrice[0] = address(comp);
            pathPrice[1] = address(want);
        } else {
            pathPrice = new address[](3);
            pathPrice[0] = address(comp);
            pathPrice[1] = address(WETH);
            pathPrice[2] = address(want);
        }

        uint256[] memory amounts = uniswapV2Router.getAmountsOut(_amount, pathPrice); // APRs are in 1e18
        return amounts[amounts.length - 1];
    }

    /// @notice Specifies the token managed by this contract during normal operation
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](3);
        protected[0] = address(want);
        protected[1] = address(cToken);
        protected[2] = comp;
        return protected;
    }
}
