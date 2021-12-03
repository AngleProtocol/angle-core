// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./CTokenI.sol";

interface IComptroller {
    function compSupplySpeeds(address cToken) external view returns (uint256);

    function claimComp(
        address[] memory holders,
        CTokenI[] memory cTokens,
        bool borrowers,
        bool suppliers
    ) external;
}
