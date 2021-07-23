// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
// OpenZeppelin may update its version of the ERC20PermitUpgradeable token
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

import "../interfaces/IAgToken.sol";

/// @title AgTokenEvents
/// @author Angle Core Team
/// @notice All the events used in `AgToken` contract
contract AgTokenEvents {
    event CapOnStablecoinUpdated(uint256 _capOnStablecoin);

    event MaxMintAmountUpdated(uint256 _maxMintAmount);
}
