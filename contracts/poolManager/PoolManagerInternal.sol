// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PoolManagerStorage.sol";

/// @title PoolManagerInternal
/// @author Angle Core Team
/// @notice The `PoolManager` contract corresponds to a collateral pool of the protocol for a stablecoin,
/// it manages a single ERC20 token. It is responsible for interacting with the strategies enabling the protocol
/// to get yield on its collateral
/// @dev This file contains all the internal functions of the `PoolManager` contract
contract PoolManagerInternal is PoolManagerStorage, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    // Roles need to be defined here because there are some internal access control functions
    // in the `PoolManagerInternal` file

    /// @notice Role for `StableMaster` only
    bytes32 public constant STABLEMASTER_ROLE = keccak256("STABLEMASTER_ROLE");
    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role for `Strategy` only
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    // ======================= Access Control and Governance =======================

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    function _addGuardian(address _guardian) internal {
        // Granting the new role
        // Access control for this contract
        _grantRole(GUARDIAN_ROLE, _guardian);
        // Propagating the new role in other contract
        perpetualManager.grantRole(GUARDIAN_ROLE, _guardian);
        feeManager.grantRole(GUARDIAN_ROLE, _guardian);
        uint256 strategyListLength = strategyList.length;
        for (uint256 i = 0; i < strategyListLength; i++) {
            IStrategy(strategyList[i]).addGuardian(_guardian);
        }
    }

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function _revokeGuardian(address guardian) internal {
        _revokeRole(GUARDIAN_ROLE, guardian);
        perpetualManager.revokeRole(GUARDIAN_ROLE, guardian);
        feeManager.revokeRole(GUARDIAN_ROLE, guardian);
        uint256 strategyListLength = strategyList.length;
        for (uint256 i = 0; i < strategyListLength; i++) {
            IStrategy(strategyList[i]).revokeGuardian(guardian);
        }
    }

    // ============================= Yield Farming =================================

    /// @notice Internal version of `updateStrategyDebtRatio`
    /// @dev Updates the debt ratio for a strategy
    function _updateStrategyDebtRatio(address strategy, uint256 _debtRatio) internal {
        StrategyParams storage params = strategies[strategy];
        require(params.lastReport != 0, "78");
        debtRatio = debtRatio + _debtRatio - params.debtRatio;
        require(debtRatio <= BASE_PARAMS, "76");
        params.debtRatio = _debtRatio;
        emit StrategyAdded(strategy, debtRatio);
    }

    // ============================ Utils ==========================================

    /// @notice Returns this `PoolManager`'s reserve of collateral (not including what has been lent)
    function _getBalance() internal view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Returns the amount of assets owned by this `PoolManager`
    /// @dev This sums the current balance of the contract to what has been given to strategies
    /// @dev This amount can be manipulated by flash loans
    function _getTotalAsset() internal view returns (uint256) {
        return _getBalance() + totalDebt;
    }
}
