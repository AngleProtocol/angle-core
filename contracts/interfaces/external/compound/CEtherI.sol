// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.5.0;

import "./CTokenI.sol";

interface CEtherI is CTokenI {
    function mint() external payable;

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);
}
