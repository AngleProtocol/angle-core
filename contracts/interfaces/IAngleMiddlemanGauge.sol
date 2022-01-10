// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

interface IAngleMiddlemanGauge {
    function pullAndBridge(uint256 amount) external;
}
