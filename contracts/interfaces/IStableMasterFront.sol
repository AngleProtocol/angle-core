// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./IStableMaster.sol";
import "./IPoolManager.sol";

/// @title IStableMasterFront
/// @author Yearn
/// @notice Interface for the `StableMasterFront` contract
interface IStableMasterFront is IStableMaster {

    /// @notice Lets a SLP enter the protocol by sending collateral to the system in exchange of sanTokens
    /// @param user Address of the SLP to send sanTokens to
    /// @param amount Amount of collateral sent
    /// @param poolManager Address of the `PoolManager` of the required collateral
    function deposit(
        uint256 amount,
        address user,
        IPoolManager poolManager
    ) external;

    /// @notice Lets a SLP burn of sanTokens and receive the corresponding collateral back in exchange at the
    /// current exchange rate between sanTokens and collateral
    /// @param amount Amount of sanTokens burnt by the SLP
    /// @param burner Address that will burn its sanTokens
    /// @param dest Address that will receive the collateral
    /// @param poolManager Address of the `PoolManager` of the required collateral
    /// @dev The `msg.sender` should have approval to burn from the `burner` or the `msg.sender` should be the `burner`
    /// @dev This transaction will fail if the `PoolManager` does not have enough reserves, the front will however be here
    /// to notify them that they cannot withdraw
    /// @dev In case there are not enough reserves, strategies should be harvested or their debt ratios should be adjusted
    /// by governance to make sure that users, HAs or SLPs withdrawing always have free collateral they can use
    function withdraw(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager
    ) external;

}
