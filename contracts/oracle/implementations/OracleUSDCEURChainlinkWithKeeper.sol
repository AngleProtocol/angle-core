// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../OracleChainlinkMultiEfficientWithKeeper.sol";

/// @title OracleUSDCEURChainlinkWithKeeper
/// @author Angle Core Team
/// @notice Gives the price of USDC in Euro in base 18 by looking at Chainlink USDC/USD and USD/EUR feeds
/// with the USD/EUR feed that is paused right after an update
contract OracleUSDCEURChainlinkWithKeeper is OracleChainlinkMultiEfficientWithKeeper {
    // solhint-disable-next-line
    string public constant description = "USDC/EUR Oracle";

    constructor(
        uint32 _stalePeriod,
        uint32 _pausingPeriod,
        ICoreBorrow _coreBorrow,
        IKeeperRegistry _keeperRegistry
    ) OracleChainlinkMultiEfficientWithKeeper(_stalePeriod, _pausingPeriod, _coreBorrow, _keeperRegistry) {}

    /// @inheritdoc OracleChainlinkMultiEfficientWithKeeper
    function circuitChainlink() public pure override returns (AggregatorV3Interface[2] memory) {
        return [
            // Oracle USDC/USD
            AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6),
            // Oracle EUR/USD
            AggregatorV3Interface(0xb49f677943BC038e9857d61E7d053CaA2C1734C1)
        ];
    }

    /// @inheritdoc OracleChainlinkMultiEfficientWithKeeper
    function _inBase() internal pure override returns (uint256) {
        return 10**6;
    }
}
