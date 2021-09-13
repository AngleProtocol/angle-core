// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

/// @title TimelockEvents
/// @author Angle Core Team
/// @notice All the events used in Timelock contract
contract TimelockEvents {
    event ExecuteTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    event QueueTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    event CancelTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );
    event NewAdmin(address indexed newAdmin);

    event NewPendingAdmin(address indexed newPendingAdmin);

    event NewDelay(uint256 indexed newDelay);
}
