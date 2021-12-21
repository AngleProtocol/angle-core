// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PoolManagerStorageV2.sol";

/// @title PoolManagerStorageV3
/// @author Angle Core Team
/// @notice The `PoolManager` contract corresponds to a collateral pool of the protocol for a stablecoin,
/// it manages a single ERC20 token. It is responsible for interacting with the strategies enabling the protocol
/// to get yield on its collateral
/// @dev This file contains the last variables and parameters stored for this contract. The reason for not storing them
/// directly in `PoolManagerStorageV1` is that theywere introduced after a first deployment and may have introduced a
/// storage clash when upgrading
contract PoolManagerStorageV3 is PoolManagerStorageV2 {
    /// @notice Address of the surplus distributor allowed to distribute rewards
    address public surplusConverter;

    /// @notice Share of the interests going to surplus and share going to SLPs
    uint64 public interestsForSurplus;

    /// @notice Interests accumulated by the protocol and to be distributed through ANGLE or veANGLE
    /// token holders
    uint256 public interestsAccumulated;

    /// @notice Debt that must be paid by admins after a loss on a strategy
    uint256 public adminDebt;
}
