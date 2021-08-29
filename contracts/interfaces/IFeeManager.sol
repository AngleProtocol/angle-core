// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./IAccessControl.sol";

/// @title IFeeManagerFunctions
/// @author Angle Core Team
/// @dev Interface for the `FeeManager` contract
interface IFeeManagerFunctions is IAccessControl {
    function deployCollateral(address[] memory governorList, address guardian) external;
}

/// @title IFeeManager
/// @author Angle Core Team
/// @notice Previous interace with additionnal getters for public variables and mappings
/// @dev We need these getters as they are used in other contracts of the protocol
interface IFeeManager is IFeeManagerFunctions {
    function stableMaster() external view returns (address);

    function perpetualManager() external view returns (address);
}
