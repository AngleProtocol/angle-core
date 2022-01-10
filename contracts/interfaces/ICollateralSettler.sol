// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title ICollateralSettler
/// @author Angle Core Team
/// @notice Interface for the collateral settlement contracts
interface ICollateralSettler {
    function triggerSettlement(
        uint256 _oracleValue,
        uint256 _sanRate,
        uint256 _stocksUsers
    ) external;
}
