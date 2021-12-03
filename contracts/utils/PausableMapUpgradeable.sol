// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title PausableMap
/// @author Angle Core Team after a fork from OpenZeppelin's similar Pausable Contracts
/// @notice Contract module which allows children to implement an emergency stop
/// mechanism that can be triggered by an authorized account.
/// @notice It generalizes Pausable from OpenZeppelin by allowing to specify a bytes32 that
/// should be stopped
/// @dev This module is used through inheritance
/// @dev In Angle's protocol, this contract is mainly used in `StableMasterFront`
/// to prevent SLPs and new stable holders from coming in
/// @dev The modifiers `whenNotPaused` and `whenPaused` from the original OpenZeppelin contracts were removed
/// to save some space and because they are not used in the `StableMaster` contract where this contract
/// is imported
contract PausableMapUpgradeable {
    /// @dev Emitted when the pause is triggered for `name`
    event Paused(bytes32 name);

    /// @dev Emitted when the pause is lifted for `name`
    event Unpaused(bytes32 name);

    /// @dev Mapping between a name and a boolean representing the paused state
    mapping(bytes32 => bool) public paused;

    /// @notice Triggers stopped state for `name`
    /// @param name Name for which to pause the contract
    /// @dev The contract must not be paused for `name`
    function _pause(bytes32 name) internal {
        require(!paused[name], "18");
        paused[name] = true;
        emit Paused(name);
    }

    /// @notice Returns to normal state for `name`
    /// @param name Name for which to unpause the contract
    /// @dev The contract must be paused for `name`
    function _unpause(bytes32 name) internal {
        require(paused[name], "19");
        paused[name] = false;
        emit Unpaused(name);
    }
}
