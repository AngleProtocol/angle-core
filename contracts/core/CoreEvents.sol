// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/ICore.sol";
import "../interfaces/IAgToken.sol";
import "../interfaces/IStableMaster.sol";

import "../utils/FunctionUtils.sol";

/// @title CoreEvents
/// @author Angle Core Team
/// @notice All the events used in the `Core` contract
contract CoreEvents {
    event StableMasterDeployed(address indexed _stableMaster, address indexed _agToken);

    event StableMasterRevoked(address indexed _stableMaster);
}
