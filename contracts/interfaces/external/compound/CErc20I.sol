// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0;

import "./CTokenI.sol";

interface CErc20I is CTokenI {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function underlying() external view returns (address);

    function borrow(uint256 borrowAmount) external returns (uint256);
}
