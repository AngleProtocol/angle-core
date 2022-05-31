// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title IAngleMiddlemanGauge
/// @author Angle Core Team
/// @notice Interface for the `AngleMiddleman` contract
interface IAngleMiddlemanGauge {
    function notifyReward(address gauge, uint256 amount) external;
}
