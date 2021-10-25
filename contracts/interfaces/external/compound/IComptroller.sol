// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

interface IComptroller {
    function compSupplySpeeds(address cToken) external view returns (uint256);
}
