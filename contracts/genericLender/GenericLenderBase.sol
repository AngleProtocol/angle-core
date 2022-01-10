// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../external/AccessControl.sol";

import "../interfaces/IGenericLender.sol";
import "../interfaces/IPoolManager.sol";
import "../interfaces/IStrategy.sol";

/// @title GenericLenderBase
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat/tree/master/contracts/GenericLender
/// @notice A base contract to build contracts to lend assets
abstract contract GenericLenderBase is IGenericLender, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    string public override lenderName;

    // ============================= References to contracts =============================

    /// @notice Reference to the protocol's collateral poolManager
    IPoolManager public poolManager;

    /// @notice Reference to the `Strategy`
    address public override strategy;

    /// @notice Reference to the token lent
    IERC20 public want;

    // ============================= Constructor =============================

    /// @notice Constructor of the `GenericLenderBase`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    constructor(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian
    ) {
        strategy = _strategy;
        // The corresponding `PoolManager` is inferred from the `Strategy`
        poolManager = IPoolManager(IStrategy(strategy).poolManager());
        want = IERC20(poolManager.token());
        lenderName = _name;

        _setupRole(GUARDIAN_ROLE, address(poolManager));
        for (uint256 i = 0; i < governorList.length; i++) {
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }
        _setupRole(GUARDIAN_ROLE, guardian);
        _setupRole(STRATEGY_ROLE, _strategy);
        _setRoleAdmin(GUARDIAN_ROLE, STRATEGY_ROLE);
        _setRoleAdmin(STRATEGY_ROLE, GUARDIAN_ROLE);

        want.safeApprove(_strategy, type(uint256).max);
    }

    // ============================= Governance =============================

    /// @notice Override this to add all tokens/tokenized positions this contract
    /// manages on a *persistent* basis (e.g. not just for swapping back to
    /// want ephemerally).
    ///
    /// Example:
    /// ```
    ///    function _protectedTokens() internal override view returns (address[] memory) {
    ///      address[] memory protected = new address[](3);
    ///      protected[0] = tokenA;
    ///      protected[1] = tokenB;
    ///      protected[2] = tokenC;
    ///      return protected;
    ///    }
    /// ```
    function _protectedTokens() internal view virtual returns (address[] memory);

    /// @notice
    /// Removes tokens from this Strategy that are not the type of tokens
    /// managed by this Strategy. This may be used in case of accidentally
    /// sending the wrong kind of token to this Strategy.
    ///
    /// Tokens will be sent to `governance()`.
    ///
    /// This will fail if an attempt is made to sweep `want`, or any tokens
    /// that are protected by this Strategy.
    ///
    /// This may only be called by governance.
    /// @param _token The token to transfer out of this poolManager.
    /// @param to Address to send the tokens to.
    /// @dev
    /// Implement `_protectedTokens()` to specify any additional tokens that
    /// should be protected from sweeping in addition to `want`.
    function sweep(address _token, address to) external override onlyRole(GUARDIAN_ROLE) {
        address[] memory __protectedTokens = _protectedTokens();
        for (uint256 i = 0; i < __protectedTokens.length; i++) require(_token != __protectedTokens[i], "93");

        IERC20(_token).safeTransfer(to, IERC20(_token).balanceOf(address(this)));
    }
}
