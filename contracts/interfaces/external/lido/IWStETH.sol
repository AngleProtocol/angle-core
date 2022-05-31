// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWStETH
/// @author Angle Core Team
/// @notice Interface for the `WStETH` contract
/// @dev This interface only contains functions of the `WStETH` which are called by other contracts
/// of this module
interface IWStETH is IERC20 {
    function stETH() external returns (address);

    function wrap(uint256 _stETHAmount) external returns (uint256);
}
