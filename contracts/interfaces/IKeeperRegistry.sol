// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @title IKeeperRegistry
/// @author Angle Core Team
interface IKeeperRegistry {
    /// @notice Checks whether an address is whitelisted during oracle updates
    /// @param caller Address for which the whitelist should be checked
    /// @return Whether if the address is trusted
    function isTrusted(address caller) external view returns (bool);
}
