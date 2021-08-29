// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "../interfaces/external/dYdX/dYdX.sol";

import "./GenericLenderBase.sol";

/// @title GenericDyDx
/// @author Forked from https://github.com/Grandthrax/yearnv2/blob/master/contracts/GenericLender/GenericDyDx.sol
/// @notice A contract to lend any ERC20 to dYdX
contract GenericDyDx is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 internal constant _SECONDS_PER_YEAR = 365 days;

    // ==================== References to contracts =============================

    address private constant _SOLO = 0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e;

    // ==================== Parameters =============================

    uint256 public dydxMarketId;

    // ============================= Constructor =============================

    constructor(
        address _strategy,
        string memory name,
        address[] memory governorList,
        address guardian
    ) GenericLenderBase(_strategy, name, governorList, guardian) {
        want.safeApprove(_SOLO, type(uint256).max);

        ISoloMargin solo = ISoloMargin(_SOLO);
        uint256 numMarkets = solo.getNumMarkets();
        address curToken;
        for (uint256 i = 0; i < numMarkets; i++) {
            curToken = solo.getMarketTokenAddress(i);

            if (curToken == address(want)) {
                dydxMarketId = i;
                return;
            }
        }
        revert("no marketId found for provided token");
    }

    // ============================= External Functions =============================

    /// @notice Deposits the current balance to the lending platform
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        _dydxDeposit(balance);
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
        _withdraw(amount);
        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    /// @notice Withdraws as much as possible
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 balance = _nav();
        uint256 returned = _withdraw(balance);
        return returned >= balance;
    }

    // ============================= External View Functions =============================

    /// @notice Returns the current total of assets managed
    function nav() external view override returns (uint256) {
        return _nav();
    }

    /// @notice Returns the current balance of cTokens
    function underlyingBalanceStored() public view returns (uint256) {
        (address[] memory cur, , Types.Wei[] memory balance) = ISoloMargin(_SOLO).getAccountBalances(_getAccountInfo());

        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i] == address(want)) {
                return balance[i].value;
            }
        }
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate
    function apr() external view override returns (uint256) {
        return _apr(0);
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate weighted by a factor
    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr(0);
        return a * _nav();
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate after a new deposit
    /// @param amount The amount to add to the lending platform
    function aprAfterDeposit(uint256 amount) external view override returns (uint256) {
        return _apr(amount);
    }

    /// @notice Check if any assets is currently managed by this contract
    function hasAssets() external view override returns (bool) {
        return underlyingBalanceStored() > 0;
    }

    // ============================= Internal Functions =============================

    /// @notice See `apr`
    function _apr(uint256 extraSupply) internal view returns (uint256) {
        ISoloMargin solo = ISoloMargin(_SOLO);
        Types.TotalPar memory par = solo.getMarketTotalPar(dydxMarketId);
        Interest.Index memory index = solo.getMarketCurrentIndex(dydxMarketId);
        address interestSetter = solo.getMarketInterestSetter(dydxMarketId);
        uint256 borrow = (uint256(par.borrow) * index.borrow) / 1e18;
        uint256 supply = ((uint256(par.supply) * index.supply) / 1e18) + extraSupply;

        uint256 borrowInterestRate = IInterestSetter(interestSetter)
            .getInterestRate(address(want), borrow, supply)
            .value;
        uint256 lendInterestRate = (borrowInterestRate * borrow) / supply;
        return lendInterestRate * _SECONDS_PER_YEAR;
    }

    /// @notice See `nav`
    function _nav() internal view returns (uint256) {
        uint256 underlying = underlyingBalanceStored();
        return want.balanceOf(address(this)) + underlying;
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = underlyingBalanceStored();
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
        uint256 liquidity = want.balanceOf(_SOLO);

        if (liquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;

            if (toWithdraw <= liquidity) {
                //we can take all
                _dydxWithdraw(toWithdraw);
            } else {
                //take all we can
                _dydxWithdraw(liquidity);
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /// @notice See `deposit`
    function _dydxDeposit(uint256 depositAmount) internal {
        ISoloMargin solo = ISoloMargin(_SOLO);

        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](1);

        operations[0] = _getDepositAction(dydxMarketId, depositAmount);

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);
    }

    /// @notice See `withdraw`
    function _dydxWithdraw(uint256 amount) internal {
        ISoloMargin solo = ISoloMargin(_SOLO);

        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](1);

        operations[0] = _getWithdrawAction(dydxMarketId, amount);

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);
    }

    function _getWithdrawAction(uint256 marketId, uint256 amount) internal view returns (Actions.ActionArgs memory) {
        return
            Actions.ActionArgs({
                actionType: Actions.ActionType.Withdraw,
                accountId: 0,
                amount: Types.AssetAmount({
                    sign: false,
                    denomination: Types.AssetDenomination.Wei,
                    ref: Types.AssetReference.Delta,
                    value: amount
                }),
                primaryMarketId: marketId,
                secondaryMarketId: 0,
                otherAddress: address(this),
                otherAccountId: 0,
                data: ""
            });
    }

    function _getDepositAction(uint256 marketId, uint256 amount) internal view returns (Actions.ActionArgs memory) {
        return
            Actions.ActionArgs({
                actionType: Actions.ActionType.Deposit,
                accountId: 0,
                amount: Types.AssetAmount({
                    sign: true,
                    denomination: Types.AssetDenomination.Wei,
                    ref: Types.AssetReference.Delta,
                    value: amount
                }),
                primaryMarketId: marketId,
                secondaryMarketId: 0,
                otherAddress: address(this),
                otherAccountId: 0,
                data: ""
            });
    }

    function _getAccountInfo() internal view returns (Account.Info memory) {
        return Account.Info({ owner: address(this), number: 0 });
    }

    /// @notice Specifies the token managed by this contract during normal operation
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }
}
