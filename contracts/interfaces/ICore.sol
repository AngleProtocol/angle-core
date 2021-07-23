// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./IStableMaster.sol";

/// @title ICore
/// @author Angle Core Team
/// @dev Interface for the core contract
interface ICoreFunctions {
    function revokeStableMaster(address stableMaster) external;

    function addGovernor(address _governor) external;

    function removeGovernor(address _governor) external;

    function setGuardian(address _guardian) external;

    function revokeGuardian() external;

    function getGovernorList() external view returns (address[] memory);
}

interface ICore is ICoreFunctions {
    function guardian() external view returns (address);
}
