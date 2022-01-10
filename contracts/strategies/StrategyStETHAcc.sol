// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.7;

import "../interfaces/external/curve/Curve.sol";
import "../interfaces/external/lido/ISteth.sol";
import "../interfaces/IWETH.sol";
import "./BaseStrategy.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/// @title StrategyStETHAcc
/// @author Forked from https://github.com/Grandthrax/yearn-steth-acc/blob/master/contracts/Strategy.sol
/// @notice A strategy designed to getting yield on wETH by putting ETH in Lido or Curve for stETH and exiting
/// for wETH
contract StrategyStETHAcc is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Current `apr` of the strategy: this apr needs to be manually filled by the strategist
    /// and updated when Lido's APR changes. It is put like that as there is no easy way to compute Lido's APR
    /// on-chain
    uint256 public apr;

    /// @notice Reference to the Curve ETH/stETH
    ICurveFi public immutable stableSwapSTETH;
    /// @notice Reference to wETH, it should normally be equal to `want`
    IWETH public immutable weth;
    /// @notice Reference to the stETH token
    ISteth public immutable stETH;

    address private _referral = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; //stratms. for recycling and redepositing
    /// @notice Maximum trade size within the strategy
    uint256 public maxSingleTrade;
    /// @notice Parameter used for slippage protection
    uint256 public constant DENOMINATOR = 10_000;
    /// @notice Slippage parameter for the swaps on Curve: out of `DENOMINATOR`
    uint256 public slippageProtectionOut; // = 50; //out of 10000. 50 = 0.5%

    /// @notice ID of wETH in the Curve pool
    int128 private constant _WETHID = 0;
    /// @notice ID of stETH in the Curve pool
    int128 private constant _STETHID = 1;

    /// @notice Constructor of the `Strategy`
    /// @param _poolManager Address of the `PoolManager` lending to this strategy
    /// @param _rewards  The token given to reward keepers.
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    /// @param _stableSwapSTETH Address of the stETH/ETH Curve pool
    /// @param _weth Address of wETH
    /// @param _stETH Address of the stETH token
    constructor(
        address _poolManager,
        IERC20 _rewards,
        address[] memory governorList,
        address guardian,
        address _stableSwapSTETH,
        address _weth,
        ISteth _stETH
    ) BaseStrategy(_poolManager, _rewards, governorList, guardian) {
        require(address(want) == _weth, "20");
        stableSwapSTETH = ICurveFi(_stableSwapSTETH);
        weth = IWETH(_weth);
        stETH = ISteth(_stETH);
        _stETH.approve(_stableSwapSTETH, type(uint256).max);
        maxSingleTrade = 1_000 * 1e18;
        slippageProtectionOut = 50;
    }

    /// @notice This contract gets ETH and so it needs this function
    receive() external payable {}

    // ========================== View Functions ===================================

    /// @notice View function to check the total assets managed by the strategy
    /// @dev We are purposely treating stETH and ETH as being equivalent.
    /// This is for a few reasons. The main one is that we do not have a good way to value
    /// stETH at any current time without creating exploit routes.
    /// Currently you can mint eth for steth but can't burn steth for eth so need to sell.
    /// Once eth 2.0 is merged you will be able to burn 1-1 as well.
    /// The main downside here is that we will noramlly overvalue our position as we expect stETH
    /// to trade slightly below peg. That means we will earn profit on deposits and take losses on withdrawals.
    /// This may sound scary but it is the equivalent of using virtualprice in a curve lp.
    /// As we have seen from many exploits, virtual pricing is safer than touch pricing.
    function estimatedTotalAssets() public view override returns (uint256) {
        return stethBalance() + wantBalance();
    }

    /// @notice Returns the wETH balance of the strategy
    function wantBalance() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @notice Returns the stETH balance of the strategy
    function stethBalance() public view returns (uint256) {
        return stETH.balanceOf(address(this));
    }

    /// @notice The ETH APR of owning stETH
    function estimatedAPR() external view returns (uint256) {
        return apr;
    }

    // ========================== Strategy Functions ===============================

    /// @notice Frees up profit plus `_debtOutstanding`.
    /// @param _debtOutstanding Amount to withdraw
    /// @return _profit Profit freed by the call
    /// @return _loss Loss discovered by the call
    /// @return _debtPayment Amount freed to reimburse the debt: it is an amount made available for the `PoolManager`
    /// @dev If `_debtOutstanding` is more than we can free we get as much as possible.
    function _prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 wantBal = wantBalance();
        uint256 stethBal = stethBalance();
        uint256 totalAssets = wantBal + stethBal;

        uint256 debt = poolManager.strategies(address(this)).totalStrategyDebt;

        if (totalAssets >= debt) {
            _profit = totalAssets - debt;

            uint256 toWithdraw = _profit + _debtOutstanding;
            // If more should be withdrawn than what's in the strategy: we divest from Curve
            if (toWithdraw > wantBal) {
                // We step our withdrawals. Adjust max single trade to withdraw more
                uint256 willWithdraw = Math.min(maxSingleTrade, toWithdraw);
                uint256 withdrawn = _divest(willWithdraw);
                if (withdrawn < willWithdraw) {
                    _loss = willWithdraw - withdrawn;
                }
            }
            wantBal = wantBalance();

            // Computing net off profit and loss
            if (_profit >= _loss) {
                _profit = _profit - _loss;
                _loss = 0;
            } else {
                _profit = 0;
                _loss = _loss - _profit;
            }

            // profit + _debtOutstanding must be <= wantbalance. Prioritise profit first
            if (wantBal < _profit) {
                _profit = wantBal;
            } else if (wantBal < toWithdraw) {
                _debtPayment = wantBal - _profit;
            } else {
                _debtPayment = _debtOutstanding;
            }
        } else {
            _loss = debt - totalAssets;
        }
    }

    /// @notice Liquidates everything and returns the amount that got freed.
    /// This function is used during emergency exit instead of `_prepareReturn()` to
    /// liquidate all of the Strategy's positions back to the Manager.
    function _liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        _divest(stethBalance());
        _amountFreed = wantBalance();
    }

    /// @notice Function called when harvesting to invest in stETH
    function _adjustPosition() internal override {
        uint256 toInvest = wantBalance();
        if (toInvest > 0) {
            uint256 realInvest = Math.min(maxSingleTrade, toInvest);
            _invest(realInvest);
        }
    }

    /// @notice Invests `_amount` wETH in stETH
    /// @param _amount Amount of wETH to put in stETH
    /// @return The amount of stETH received from the investment
    /// @dev This function chooses the optimal route between going to Lido directly or doing a swap on Curve
    /// @dev This function automatically wraps wETH to ETH
    function _invest(uint256 _amount) internal returns (uint256) {
        uint256 before = stethBalance();
        // Unwrapping the tokens
        weth.withdraw(_amount);
        // Test if we should buy from Curve instead of minting from Lido
        uint256 out = stableSwapSTETH.get_dy(_WETHID, _STETHID, _amount);
        if (out < _amount) {
            // If we get less than one stETH per wETH we use Lido
            stETH.submit{ value: _amount }(_referral);
        } else {
            // Otherwise, we do a Curve swap
            stableSwapSTETH.exchange{ value: _amount }(_WETHID, _STETHID, _amount, _amount);
        }

        return stethBalance() - before;
    }

    /// @notice Divests stETH on Curve and gets wETH back to the strategy in exchange
    /// @param _amount Amount of stETH to divest
    /// @dev Curve is the only place to convert stETH to ETH
    function _divest(uint256 _amount) internal returns (uint256) {
        uint256 before = wantBalance();

        // Computing slippage protection for the swap
        uint256 slippageAllowance = (_amount * (DENOMINATOR - slippageProtectionOut)) / DENOMINATOR;
        // Curve swap
        stableSwapSTETH.exchange(_STETHID, _WETHID, _amount, slippageAllowance);

        weth.deposit{ value: address(this).balance }();

        return wantBalance() - before;
    }

    /// @notice Attempts to withdraw `_amountNeeded` from the strategy and lets the user decide if they take the loss or not
    /// @param _amountNeeded Amount to withdraw from the strategy
    function _liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = wantBalance();
        if (wantBal < _amountNeeded) {
            uint256 toWithdraw = _amountNeeded - wantBal;
            uint256 withdrawn = _divest(toWithdraw);
            if (withdrawn < toWithdraw) {
                _loss = toWithdraw - withdrawn;
            }
        }

        _liquidatedAmount = _amountNeeded - _loss;
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function _protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(stETH);

        return protected;
    }

    // ============================ Governance =====================================

    /// @notice Updates the referral code for Lido
    /// @param newReferral Address of the new referral
    function updateReferral(address newReferral) public onlyRole(GUARDIAN_ROLE) {
        _referral = newReferral;
    }

    /// @notice Updates the size of a trade in the strategy
    /// @param _maxSingleTrade New `maxSingleTrade` value
    function updateMaxSingleTrade(uint256 _maxSingleTrade) public onlyRole(GUARDIAN_ROLE) {
        maxSingleTrade = _maxSingleTrade;
    }

    /// @notice Changes the estimated APR of the strategy
    /// @param _apr New strategy APR
    function setApr(uint256 _apr) public onlyRole(GUARDIAN_ROLE) {
        apr = _apr;
    }

    /// @notice Updates the maximum slippage protection parameter
    /// @param _slippageProtectionOut New slippage protection parameter
    function updateSlippageProtectionOut(uint256 _slippageProtectionOut) public onlyRole(GUARDIAN_ROLE) {
        slippageProtectionOut = _slippageProtectionOut;
    }

    /// @notice Invests `_amount` in stETH
    /// @param _amount Amount to invest
    /// @dev This function allows to override the behavior that could be obtained through `harvest` calls
    function invest(uint256 _amount) external onlyRole(GUARDIAN_ROLE) {
        require(wantBalance() >= _amount);
        uint256 realInvest = Math.min(maxSingleTrade, _amount);
        _invest(realInvest);
    }

    /// @notice Rescues stuck ETH from the strategy
    /// @dev This strategy should never have stuck eth, but let it just in case
    function rescueStuckEth() external onlyRole(GUARDIAN_ROLE) {
        weth.deposit{ value: address(this).balance }();
    }

    // ========================== Manager functions ================================

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    /// @dev This internal function has to be put in this file because `AccessControl` is not defined
    /// in `PoolManagerInternal`
    function addGuardian(address _guardian) external override onlyRole(POOLMANAGER_ROLE) {
        // Granting the new role
        // Access control for this contract
        _grantRole(GUARDIAN_ROLE, _guardian);
    }

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function revokeGuardian(address guardian) external override onlyRole(POOLMANAGER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, guardian);
    }
}
