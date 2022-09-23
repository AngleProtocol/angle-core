// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../OracleChainlinkMultiEfficient.sol";

/// @title OracleUSDCEURChainlink
/// @author Angle Core Team
/// @notice Gives the price of USDC in Euro in base 18 by looking at Chainlink USDC/USD and USD/EUR feeds
contract OracleUSDCEURChainlink is OracleChainlinkMultiEfficient {
    string public constant DESCRIPTION = "USDC/EUR Oracle";

    constructor(uint32 _stalePeriod, address[] memory guardians)
        OracleChainlinkMultiEfficient(_stalePeriod, guardians)
    {}

    function _circuitChainlink() internal pure override returns (AggregatorV3Interface[2] memory) {
        return [
            // Oracle USDC/USD
            AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6),
            // Oracle EUR/USD
            AggregatorV3Interface(0xb49f677943BC038e9857d61E7d053CaA2C1734C1)
        ];
    }

    function _inBase() internal pure override returns (uint256) {
        return 10**6;
    }

    // No need to override the `_chainlinkDecimals()` and `_circuitChainIsMultiplied()` functions
}
