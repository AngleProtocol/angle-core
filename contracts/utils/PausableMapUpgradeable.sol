// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/// @title PausableMap
/// @author Angle Core Team after a fork from OpenZeppelin's similar Pausable Contracts
/// @notice Contract module which allows children to implement an emergency stop
/// mechanism that can be triggered by an authorized account.
/// @notice It generalizes Pausable from OpenZeppelin by allowing to specify a bytes32 that
/// should be stopped
/// @dev This module is used through inheritance
/// @dev In Angle's protocol, this contract is mainly `StableMasterFront`
/// to prevent HAs, SLPs and new stable holders from coming in
/// @dev The modifiers `whenNotPaused` and `whenPaused` from the original Open Zeppelin contracts were removed
/// to save some space and because they are not used in the `StableMaster` contract where this contract
/// is imported
abstract contract PausableMapUpgradeable is ContextUpgradeable {
    /// @dev Emitted when the pause is triggered by `account` for `name`
    event Paused(bytes32 name, address account);

    /// @dev Emitted when the pause is lifted by `account` for `name`
    event Unpaused(bytes32 name, address account);

    /// @dev Mapping between a name and a boolean representing the paused state
    mapping(bytes32 => bool) private _paused;

    /// @notice Returns true if the contract is paused for `name`, and false otherwise.
    /// @param name Name for which to check if the contract is paused for
    /// @return A boolean to see if the contract is paused for the entry `name`
    function paused(bytes32 name) public view virtual returns (bool) {
        return _paused[name];
    }

    /// @notice Triggers stopped state for `name`
    /// @param name Name for which to pause the contract
    /// @dev The contract must not be paused for `name`
    function _pause(bytes32 name) internal virtual {
        require(!paused(name), "paused");
        _paused[name] = true;
        emit Paused(name, _msgSender());
    }

    /// @notice Returns to normal state for `name`
    /// @param name Name for which to unpause the contract
    /// @dev The contract must be paused for `name`
    function _unpause(bytes32 name) internal virtual {
        require(paused(name), "not paused");
        _paused[name] = false;
        emit Unpaused(name, _msgSender());
    }
}
