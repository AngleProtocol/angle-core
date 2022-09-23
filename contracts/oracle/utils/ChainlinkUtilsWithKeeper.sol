// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../interfaces/IKeeperRegistry.sol";
import "../../interfaces/ICoreBorrow.sol";

/// @title ChainlinkUtilsWithKeeper
/// @author Angle Core Team
/// @notice Utility contract that is used to read for Chainlink feeds with the possibility to pause
/// the oracle after each oracle update
abstract contract ChainlinkUtilsWithKeeper {
    /// @notice Maximum amount of time (in seconds) between each Chainlink update
    /// before the price feed is considered stale
    uint32 public stalePeriod;

    /// @notice Number of seconds during which the oracle needs to be paused after each update
    uint32 public pausingPeriod;

    /// @notice Holds the mapping of whitelisted keepers
    IKeeperRegistry public keeperRegistry;

    /// @notice Contract handling access control
    ICoreBorrow public coreBorrow;

    error InvalidChainlinkRate();
    error NotGovernorOrGuardianChainlink();
    error NotGovernor();
    error OraclePaused();

    /// @notice Checks whether the `msg.sender` has the governor role or the guardian role
    modifier onlyGovernorOrGuardian() {
        if (!coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardianChainlink();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor role
    modifier onlyGovernor() {
        if (!coreBorrow.isGovernor(msg.sender)) revert NotGovernor();
        _;
    }

    /// @notice Reads a Chainlink feed using a quote amount and converts the quote amount to
    /// the out-currency
    /// @param quoteAmount The amount for which to compute the price expressed with base decimal
    /// @param feed Chainlink feed to query
    /// @param pauseAfterUpdate Whether to pause the oracle after each update
    /// @param multiplied Whether the ratio outputted by Chainlink should be multiplied or divided
    /// to the `quoteAmount`
    /// @param decimals Number of decimals of the corresponding Chainlink pair
    /// @param castedRatio Whether a previous rate has already been computed for this feed
    /// This is mostly used in the `_changeUniswapNotFinal` function of the oracles
    /// @return The `quoteAmount` converted in out-currency (computed using the second return value)
    /// @return The value obtained with the Chainlink feed queried casted to uint
    /// @dev In this implementation, the Chainlink feed can be paused for unregistered addresses after
    /// an oracle update is `pauseAfterUpdate` is true
    function _readChainlinkFeed(
        uint256 quoteAmount,
        AggregatorV3Interface feed,
        uint8 pauseAfterUpdate,
        uint8 multiplied,
        uint256 decimals,
        uint256 castedRatio
    ) internal view returns (uint256, uint256) {
        if (castedRatio == 0) {
            (uint80 roundId, int256 ratio, , uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
            if (
                pauseAfterUpdate == 1 &&
                updatedAt + pausingPeriod > block.timestamp &&
                //solhint-disable-next-line
                !keeperRegistry.isTrusted(tx.origin)
            ) revert OraclePaused();
            if (ratio <= 0 || roundId > answeredInRound || block.timestamp - updatedAt > stalePeriod)
                revert InvalidChainlinkRate();
            castedRatio = uint256(ratio);
        }
        // Checking whether we should multiply or divide by the ratio computed
        if (multiplied == 1) quoteAmount = (quoteAmount * castedRatio) / (10**decimals);
        else quoteAmount = (quoteAmount * (10**decimals)) / castedRatio;
        return (quoteAmount, castedRatio);
    }

    /// @notice Changes the `stalePeriod`
    /// @param _stalePeriod New stale period (in seconds)
    function changeStalePeriod(uint32 _stalePeriod) external onlyGovernorOrGuardian {
        stalePeriod = _stalePeriod;
    }

    /// @notice Changes the `pausingPeriod`
    /// @param _pausingPeriod New period
    function changePausingPeriod(uint32 _pausingPeriod) external onlyGovernorOrGuardian {
        pausingPeriod = _pausingPeriod;
    }

    /// @notice Changes the `keeperRegistry` address
    /// @param _keeperRegistry New registry
    function changeKeeperRegistry(IKeeperRegistry _keeperRegistry) external onlyGovernorOrGuardian {
        keeperRegistry = _keeperRegistry;
    }

    /// @notice Changes the `coreBorrow` address
    /// @param _coreBorrow New CoreBorrow
    function changeCoreBorrow(ICoreBorrow _coreBorrow) external onlyGovernor {
        coreBorrow = _coreBorrow;
    }
}
