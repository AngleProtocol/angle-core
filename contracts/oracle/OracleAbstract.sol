// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "../interfaces/IOracle.sol";

/// @title OracleAbstract
/// @author Angle Core Team
/// @notice Abstract Oracle contract that contains some of the functions that are used across all oracle contracts
/// @dev This is the most generic form of oracle contract
/// @dev A rate gives the price of the out-currency with respect to the in-currency in base `BASE`. For instance
/// if the out-currency is ETH worth 1000 USD, then the rate ETH-USD is 10**21
abstract contract OracleAbstract is IOracle {
    /// @notice Base used for computation
    uint256 public constant BASE = 10**18;
    /// @notice Unit of the in-currency
    uint256 public override inBase;
    /// @notice Description of the assets concerned by the oracle and the price outputted
    bytes32 public description;

    /// @notice Reads one of the rates from the circuits given
    /// @return rate The current rate between the in-currency and out-currency
    /// @dev By default if the oracle involves a Uniswap price and a Chainlink price
    /// this function will return the Uniswap price
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function read() external view virtual override returns (uint256 rate);

    /// @notice Read rates from the circuit of both Uniswap and Chainlink if there are both circuits
    /// else returns twice the same price
    /// @return Return all available rates (Chainlink and Uniswap) with the lowest rate returned first.
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function readAll() external view override returns (uint256, uint256) {
        return _readAll(inBase);
    }

    /// @notice Reads rates from the circuit of both Uniswap and Chainlink if there are both circuits
    /// and returns either the highest of both rates or the lowest
    /// @return rate The lower rate between Chainlink and Uniswap
    /// @dev If there is only one rate computed in an oracle contract, then the only rate is returned
    /// regardless of the value of the `lower` parameter
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function readLower() external view override returns (uint256 rate) {
        (rate, ) = _readAll(inBase);
    }

    /// @notice Reads rates from the circuit of both Uniswap and Chainlink if there are both circuits
    /// and returns either the highest of both rates or the lowest
    /// @return rate The upper rate between Chainlink and Uniswap
    /// @dev If there is only one rate computed in an oracle contract, then the only rate is returned
    /// regardless of the value of the `lower` parameter
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function readUpper() external view override returns (uint256 rate) {
        (, rate) = _readAll(inBase);
    }

    /// @notice Converts an in-currency quote amount to out-currency using one of the rates available in the oracle
    /// contract
    /// @param quoteAmount Amount (in the input collateral) to be converted to be converted in out-currency
    /// @return Quote amount in out-currency from the base amount in in-currency
    /// @dev Like in the read function, if the oracle involves a Uniswap and a Chainlink price, this function
    /// will use the Uniswap price to compute the out quoteAmount
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function readQuote(uint256 quoteAmount) external view virtual override returns (uint256);

    /// @notice Returns the lowest quote amount between Uniswap and Chainlink circuits (if possible). If the oracle
    /// contract only involves a single feed, then this returns the value of this feed
    /// @param quoteAmount Amount (in the input collateral) to be converted
    /// @return The lowest quote amount from the quote amount in in-currency
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function readQuoteLower(uint256 quoteAmount) external view override returns (uint256) {
        (uint256 quoteSmall, ) = _readAll(quoteAmount);
        return quoteSmall;
    }

    /// @notice Returns Uniswap and Chainlink values (with the first one being the smallest one) or twice the same value
    /// if just Uniswap or just Chainlink is used
    /// @param quoteAmount Amount expressed in the in-currency base.
    /// @dev If `quoteAmount` is `inBase`, rates are returned
    /// @return The first return value is the lowest value and the second parameter is the highest
    /// @dev The rate returned is expressed with base `BASE` (and not the base of the out-currency)
    function _readAll(uint256 quoteAmount) internal view virtual returns (uint256, uint256) {}
}
