// SPDX-License-Identifier: GPL-3.0-or-later

// contracts/oracle/OracleChainlinkSingle.sol
pragma solidity 0.8.2;

import "./OracleAbstract.sol";
import "./modules/ModuleChainlinkSingle.sol";

/// @title OracleChainlinkSingle
/// @author Angle Core Team
/// @notice Oracle contract, one contract is deployed per collateral/stablecoin pair
/// @dev This contract concerns an oracle that only uses Chainlink and a single pool
/// @dev This is mainly going to be the contract used for the USD/EUR pool (or for other fiat currencies)
/// @dev Like all oracle contracts, this contract is an instance of `OracleAstract` that contains some
/// base functions
contract OracleChainlinkSingle is OracleAbstract, ModuleChainlinkSingle {
    /// @notice Constructor for the oracle using a single Chainlink pool
    /// @param _poolChainlink Chainlink pool address
    /// @param _chainIsMultiplied Whether we should multiply or divide by the Chainlink rate the
    /// in-currency amount to get the out-currency amount
    /// @param _inBase Number of units of the in-currency
    constructor(
        address _poolChainlink,
        uint256 _chainIsMultiplied,
        uint256 _inBase
    ) ModuleChainlinkSingle(_poolChainlink, _chainIsMultiplied) {
        inBase = _inBase;
    }

    /// @notice Reads the rate from the Chainlink feed
    /// @return rate The current rate between the in-currency and out-currency
    function read() external view override returns (uint256 rate) {
        (rate, ) = _quoteChainlink(BASE);
    }

    /// @notice Converts an in-currency quote amount to out-currency using Chainlink's feed
    /// @param quoteAmount Amount (in the input collateral) to be converted in out-currency
    /// @return Quote amount in out-currency from the base amount in in-currency
    /// @dev The amount returned is expressed with base `BASE` (and not the base of the out-currency)
    function readQuote(uint256 quoteAmount) external view override returns (uint256) {
        return _readQuote(quoteAmount);
    }

    /// @notice Returns Chainlink quote value twice
    /// @param quoteAmount Amount expressed in the in-currency base.
    /// @dev If quoteAmount is `inBase`, rates are returned
    /// @return The two return values are similar in this case
    function _readAll(uint256 quoteAmount) internal view override returns (uint256, uint256) {
        uint256 quote = _readQuote(quoteAmount);
        return (quote, quote);
    }

    /// @notice Internal function to convert an in-currency quote amount to out-currency using Chainlink's feed
    /// @param quoteAmount Amount (in the input collateral) to be converted to be converted in out-currency
    function _readQuote(uint256 quoteAmount) internal view returns (uint256) {
        quoteAmount = (quoteAmount * BASE) / inBase;
        (quoteAmount, ) = _quoteChainlink(quoteAmount);
        // We return only rates with base BASE
        return quoteAmount;
    }
}
