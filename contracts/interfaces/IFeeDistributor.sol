// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title IFeeDistributor
/// @author Interface of the `FeeDistributor` contract
/// @dev This interface is used by the `SurplusConverter` contract to send funds to the `FeeDistributor`
interface IFeeDistributor {
    function burn(address token) external;
}
