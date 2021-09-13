// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "../external/AccessControl.sol";

import "../interfaces/ICore.sol";
import "../interfaces/IAgToken.sol";
import "../interfaces/IStableMaster.sol";

/// @title CoreEvents
/// @author Angle Core Team
/// @notice All the events used in the `Core` contract
contract CoreEvents {
    event StableMasterDeployed(address indexed _stableMaster, address indexed _agToken);

    event StableMasterRevoked(address indexed _stableMaster);

    event GovernorRoleGranted(address indexed governor);

    event GovernorRoleRevoked(address indexed governor);

    event GuardianRoleChanged(address indexed oldGuardian, address indexed newGuardian);

    event CoreChanged(address indexed newCore);
}
