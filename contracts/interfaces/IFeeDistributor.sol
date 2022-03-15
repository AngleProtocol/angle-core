// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title IFeeDistributor
/// @author Interface of the `FeeDistributor` contract
/// @dev This interface is used by the `SurplusConverter` contract to send funds to the `FeeDistributor`
interface IFeeDistributor {
    function burn(address token) external;
}

/// @title IFeeDistributorFront
/// @author Interface for public use of the `FeeDistributor` contract
/// @dev This interface is used for user related function
interface IFeeDistributorFront {
    function token() external returns (address);

    function claim(address _addr) external returns (uint256);

    function claim(address[20] memory _addr) external returns (bool);
}