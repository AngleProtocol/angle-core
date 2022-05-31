// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStETH is IERC20 {
    event Submitted(address sender, uint256 amount, address referral);

    function submit(address) external payable returns (uint256);

    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}
