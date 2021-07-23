// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title IFeeManager
/// @author Angle Core Team
/// @dev Interface for the `FeeManager` contract
/// @dev Only the functions which are called by other contracts of Angle are left in this interface
interface IFeeManager is IAccessControl {
    function deployCollateral(address[] memory governorList, address guardian) external;
}
