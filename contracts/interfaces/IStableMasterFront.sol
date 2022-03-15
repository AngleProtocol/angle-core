// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./IStableMaster.sol";
import "./IPoolManager.sol";

/// @title IStableMasterFront
/// @author Yearn
/// @notice Interface for the `StableMasterFront` contract
interface IStableMasterFront is IStableMaster {

    function mint(
        uint256 amount,
        address user,
        IPoolManager poolManager,
        uint256 minStableAmount
    ) external;

    function burn(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager,
        uint256 minCollatAmount
    ) external;

    function deposit(
        uint256 amount,
        address user,
        IPoolManager poolManager
    ) external;

    function withdraw(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager
    ) external;

    function agToken() external view returns (address);

}
