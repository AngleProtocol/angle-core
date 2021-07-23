// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "./IPoolManager.sol";

/// @title IAgToken
/// @author Angle Core Team
/// @notice Interface for the stablecoins `AgToken` contracts
/// @dev The only functions that are left in the interface are the functions which are used
/// at another point in the protocol by a different contract
interface IAgTokenFunctions is IERC20Upgradeable, IAccessControlUpgradeable {
    // ======================= `StableMaster` functions ============================
    function deploy(address[] memory governorList, address guardian) external;

    function mint(address account, uint256 amount) external;

    function burnFrom(
        uint256 amount,
        address burner,
        address sender
    ) external;

    function burnSelf(uint256 amount, address burner) external;

    // ========================= External functions ================================

    function burnFromNoRedeem(address account, uint256 amount) external;
}

interface IAgToken is IAgTokenFunctions {
    function stableMaster() external view returns (address);
}
