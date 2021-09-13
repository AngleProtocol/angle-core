// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "../external/FullMath.sol";

/// @title OracleMath
/// @author Forked and adapted by Angle Core Team from https://github.com/Uniswap/uniswap-v3-core/blob/main/contracts/libraries/TickMath.sol
/// @notice Math library for computing prices from ticks
/// @dev Computes price for ticks of size 1.0001, i.e. sqrt(1.0001^tick). Supports
/// prices between 2**-128 and 2**128
contract OracleMath is FullMath {
    /// @dev Maximum tick that may be passed to `_getSqrtRatioAtTick` computed from log base 1.0001 of 2**128
    int24 internal constant _MAX_TICK = 887272;

    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param multiply Boolean representing whether the `baseToken` has a lower address than the `quoteToken`
    /// @return quoteAmount Amount of `quoteToken` received for `baseAmount` of `baseToken`
    function _getQuoteAtTick(
        int24 tick,
        uint256 baseAmount,
        uint256 multiply
    ) internal pure returns (uint256 quoteAmount) {
        uint256 ratio = _getRatioAtTick(tick);

        quoteAmount = (multiply == 1) ? _mulDiv(ratio, baseAmount, 1e18) : _mulDiv(1e18, baseAmount, ratio);
    }

    /// @notice Calculates 1.0001^tick * in out ERC20 decimals
    /// @dev Adapted from Uniswap `_getSqrtRatioAtTick` but we don't consider the square root
    /// anymore but directly the full rate
    /// @dev Throws if `|tick| > max tick`
    /// @param tick The input tick for the above formula
    /// @return rate uint256 representing the ratio of the two assets `(token1/token0) * 10**decimals(token1)`
    /// at the given tick
    function _getRatioAtTick(int24 tick) internal pure returns (uint256 rate) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(_MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfff97272373d413259a46990580e213a : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x149b34ee7ac262) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // We need to modify the 96 decimal to be able to convert it to a D256
        // 2**59 ~ 10**18 (thus we guarantee the same precision) and 128-59 = 69
        // We retrieve a Q128.59 decimal. --> we have 69 bits free to reach the uint256 limit.
        // Now, 2**69 >> 10**18 so we are safe in the Decimal conversion.

        uint256 price = uint256((ratio >> 69) + (ratio % (1 << 69) == 0 ? 0 : 1));
        rate = ((price * 1e18) >> 59);
    }
}
