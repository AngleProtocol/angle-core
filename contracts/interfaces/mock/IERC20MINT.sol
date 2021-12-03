// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IERC20MINT is IERC20 {
    function mint(address account, uint256 amount) external;
}
