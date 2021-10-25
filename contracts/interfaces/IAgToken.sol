// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @title IAgToken
/// @author Angle Core Team
/// @notice Interface for the stablecoins `AgToken` contracts
/// @dev The only functions that are left in the interface are the functions which are used
/// at another point in the protocol by a different contract
interface IAgToken is IERC20Upgradeable {
    // ======================= `StableMaster` functions ============================
    function mint(address account, uint256 amount) external;

    function burnFrom(
        uint256 amount,
        address burner,
        address sender
    ) external;

    function burnSelf(uint256 amount, address burner) external;

    // ========================= External function =================================

    function stableMaster() external view returns (address);
}
