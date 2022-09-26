// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./utils/ChainlinkUtils.sol";

/// @title OracleChainlinkMultiEfficient
/// @author Angle Core Team
/// @notice Abstract contract to build oracle contracts looking at Chainlink feeds on top of
/// @dev This is contract should be overriden with the correct addresses of the Chainlink feed
/// and the right amount of decimals
abstract contract OracleChainlinkMultiEfficient is ChainlinkUtils {
    // =============================== Constants ===================================

    uint256 public constant OUTBASE = 10**18;
    uint256 public constant BASE = 10**18;

    // =============================== Errors ======================================

    error InvalidLength();
    error ZeroAddress();

    /// @notice Constructor of the contract
    /// @param _stalePeriod Minimum feed update frequency for the oracle to not revert
    /// @param guardians List of guardian addresses
    constructor(uint32 _stalePeriod, address[] memory guardians) {
        stalePeriod = _stalePeriod;
        if (guardians.length == 0) revert InvalidLength();
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == address(0)) revert ZeroAddress();
            _setupRole(GUARDIAN_ROLE_CHAINLINK, guardians[i]);
        }
        _setRoleAdmin(GUARDIAN_ROLE_CHAINLINK, GUARDIAN_ROLE_CHAINLINK);
    }

    /// @notice Returns twice the value obtained from Chainlink feeds
    function readAll() external view returns (uint256, uint256) {
        uint256 quote = _quoteChainlink(BASE);
        return (quote, quote);
    }

    /// @notice Returns the outToken value of 1 inToken
    function read() external view returns (uint256 rate) {
        rate = _quoteChainlink(BASE);
    }

    /// @notice Returns the value of the inToken obtained from Chainlink feeds
    function readLower() external view returns (uint256 rate) {
        rate = _quoteChainlink(BASE);
    }

    /// @notice Returns the value of the inToken obtained from Chainlink feeds
    function readUpper() external view returns (uint256 rate) {
        rate = _quoteChainlink(BASE);
    }

    /// @notice Converts a quote amount of inToken to an outToken amount using Chainlink rates
    function readQuote(uint256 quoteAmount) external view returns (uint256) {
        return _readQuote(quoteAmount);
    }

    /// @notice Converts a quote amount of inToken to an outToken amount using Chainlink rates
    function readQuoteLower(uint256 quoteAmount) external view returns (uint256) {
        return _readQuote(quoteAmount);
    }

    /// @notice Internal function to convert an in-currency quote amount to out-currency using Chainlink's feed
    function _readQuote(uint256 quoteAmount) internal view returns (uint256) {
        quoteAmount = (quoteAmount * BASE) / _inBase();
        // We return only rates with base BASE
        return _quoteChainlink(quoteAmount);
    }

    /// @notice Reads oracle price using a Chainlink circuit
    /// @param quoteAmount The amount for which to compute the price expressed with base decimal
    /// @return The `quoteAmount` converted in EUR
    /// @dev If `quoteAmount` is `BASE_TOKENS`, the output is the oracle rate
    function _quoteChainlink(uint256 quoteAmount) internal view returns (uint256) {
        AggregatorV3Interface[2] memory circuitChainlink = _circuitChainlink();
        uint8[2] memory circuitChainIsMultiplied = _circuitChainIsMultiplied();
        uint8[2] memory chainlinkDecimals = _chainlinkDecimals();
        for (uint256 i = 0; i < circuitChainlink.length; i++) {
            (quoteAmount, ) = _readChainlinkFeed(
                quoteAmount,
                circuitChainlink[i],
                circuitChainIsMultiplied[i],
                chainlinkDecimals[i],
                0
            );
        }
        return quoteAmount;
    }

    /// @notice Returns the base of the inToken
    /// @dev This function is a necessary function to keep in the interface of oracle contracts interacting with
    /// the core module of the protocol
    function inBase() external pure returns (uint256) {
        return _inBase();
    }

    /// @notice Returns the array of the Chainlink feeds to look at
    function _circuitChainlink() internal pure virtual returns (AggregatorV3Interface[2] memory);

    /// @notice Base of the inToken
    function _inBase() internal pure virtual returns (uint256);

    /// @notice Amount of decimals of the Chainlink feeds of interest
    /// @dev This function is initialized with a specific amounts of decimals but should be overriden
    /// if a Chainlink feed does not have 8 decimals
    function _chainlinkDecimals() internal pure virtual returns (uint8[2] memory) {
        return [8, 8];
    }

    /// @notice Whether the Chainlink feeds should be multiplied or divided with one another
    function _circuitChainIsMultiplied() internal pure virtual returns (uint8[2] memory) {
        return [1, 0];
    }
}
