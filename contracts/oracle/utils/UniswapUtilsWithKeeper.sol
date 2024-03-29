// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../../utils/OracleMath.sol";
import "../../interfaces/ICoreBorrow.sol";

/// @title UniswapUtils
/// @author Angle Core Team
/// @notice Utility contract that is used in the Uniswap module contract
abstract contract UniswapUtilsWithKeeper is OracleMath {
    // The parameters below are common among the different Uniswap modules contracts

    /// @notice Time weigthed average window that should be used for each Uniswap rate
    /// It is mainly going to be 5 minutes in the protocol
    uint32 public twapPeriod;

    error NotGovernorOrGuardianUniswap();

    /// @notice Returns the `coreBorrow` address
    function _getCoreBorrow() internal view virtual returns (ICoreBorrow) {}

    /// @notice Gets a quote for an amount of in-currency using UniswapV3 TWAP and converts this
    /// amount to out-currency
    /// @param quoteAmount The amount to convert in the out-currency
    /// @param pool UniswapV3 pool to query
    /// @param isUniMultiplied Whether the rate corresponding to the Uniswap pool should be multiplied or divided
    /// @return The value of the `quoteAmount` expressed in out-currency
    function _readUniswapPool(
        uint256 quoteAmount,
        IUniswapV3Pool pool,
        uint8 isUniMultiplied
    ) internal view returns (uint256) {
        uint32[] memory secondAgos = new uint32[](2);

        secondAgos[0] = twapPeriod;
        secondAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int32(twapPeriod));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapPeriod)) != 0))
            timeWeightedAverageTick--;

        // Computing the `quoteAmount` from the ticks obtained from Uniswap
        return _getQuoteAtTick(timeWeightedAverageTick, quoteAmount, isUniMultiplied);
    }

    /// @notice Changes the TWAP period
    /// @param _twapPeriod New window to compute the TWAP
    function changeTwapPeriod(uint32 _twapPeriod) external {
        if (!_getCoreBorrow().isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardianUniswap();
        require(int32(_twapPeriod) > 0, "99");
        twapPeriod = _twapPeriod;
    }
}
