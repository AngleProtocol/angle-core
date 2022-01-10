// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PoolManagerStorageV1.sol";

/// @title PoolManagerStorageV2
/// @author Angle Core Team
/// @notice The `PoolManager` contract corresponds to a collateral pool of the protocol for a stablecoin,
/// it manages a single ERC20 token. It is responsible for interacting with the strategies enabling the protocol
/// to get yield on its collateral
/// @dev This file imports the `AccessControlUpgradeable`
contract PoolManagerStorageV2 is PoolManagerStorageV1, AccessControlUpgradeable {

}
