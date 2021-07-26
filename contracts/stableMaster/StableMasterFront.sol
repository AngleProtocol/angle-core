// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./StableMaster.sol";

/// @title StableMasterFront
/// @author Angle Core Team
/// @notice `StableMaster` is the contract handling all the collateral types accepted for a given stablecoin
/// It does all the accounting and is the point of entry in the protocol for stable holders and seekers as well as SLPs
/// @dev This file contains the front end, that is all external functions associated to the given stablecoin
contract StableMasterFront is StableMaster {
    using SafeERC20 for IERC20;

    // ============================ CONSTRUCTORS AND DEPLOYERS =====================

    /// @notice Initializes the `StableMaster` contract
    /// @param _core Address of the `Core` contract handling all the different `StableMaster` contracts
    function initialize(address _core) external zeroCheck(_core) initializer {
        __AccessControl_init();
        // Access control
        core = ICore(_core);
        _setupRole(CORE_ROLE, _core);
        // `Core` is admin of governor and governor is admin of `Core`
        // Governor will be able to change the reference to the `Core` contract and to grant and revoke
        // the `CORE_ROLE`
        _setRoleAdmin(CORE_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GOVERNOR_ROLE, CORE_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, CORE_ROLE);
        // All the roles that are specific to a given collateral can be changed by the governor
        // in the `deployCollateral`, `revokeCollateral` and `setFeeManager` functions by updating the `contractMap`
    }

    // ============================= USERS =========================================

    /// @notice Lets a user add collateral to the system to mint stablecoins
    /// @param amount Amount of collateral sent
    /// @param user Address of the contract or the person to give the minted tokens to
    /// @param poolManager Address of the `PoolManager` of the required collateral
    /// @dev To check that the `PoolManager` is valid, the contract verifies that
    /// the collateral associated to it has well a token associated to it
    /// @dev It is impossible to mint tokens and to have them sent to the zero address: there
    /// would be an issue with the `_mint` function called by the `AgToken` contract
    function mint(
        uint256 amount,
        address user,
        IPoolManager poolManager
    ) external {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        // Checking if the contract is paused for this agent
        _whenNotPaused(STABLE, address(poolManager));

        // No overflow check needed for the amount since it's never casted to int and Solidity 0.8.0
        // automatically handles overflows
        col.token.safeTransferFrom(msg.sender, address(poolManager), amount);

        uint256 fees = _computeFeeMint(amount, col);

        // Computing the net amount that will be taken into account for this user
        uint256 amountForUserInC = (amount * (BASE - fees)) / BASE;

        int256 stocksUsersUpdateValue = int256(amountForUserInC);
        // The conditions to make this require fail are hard to reach, you typically need `BASE = 1`
        // Indeed `amount` needs to be big, but you multiply it by `BASE` to compute `amountForUserInC`:
        // this multiplication normally reverts in case of large amounts
        require(stocksUsersUpdateValue >= 0, "overflow");
        // Updating the `stocksUsers` for this collateral, that is the amount of collateral that was
        // brought by users
        col.stocksUsers += stocksUsersUpdateValue;
        emit StocksUsersUpdated(address(col.token), col.stocksUsers);

        // Distributing the exact amount of fees taken to SLPs
        _accumulateFees(amount - amountForUserInC, col);

        // Getting a quote for the amount of stablecoins to issue
        // We read the lowest oracle value we get for this collateral/stablecoin pair to reduce front running risk
        // Decimals are handled directly in the oracle contract
        uint256 amountForUserInStable = col.oracle.readQuoteLower(amountForUserInC);
        // Minting
        agToken.mint(user, amountForUserInStable);
    }

    /// @notice Updates variables to take the burn of agTokens (stablecoins) into account, computes transaction
    /// fees and gives collateral from the `PoolManager` in exchange for that
    /// @param amount Amount of stable asset burnt
    /// @param burner Address from which the agTokens will be burnt
    /// @param dest Address where collateral is going to be
    /// @param poolManager Collateral type requested by the user burning
    /// @dev The `msg.sender` should have approval to burn from the `burner` or the `msg.sender` should be the `burner`
    function burn(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager
    ) external {
        // Searching collateral data
        Collateral storage col = collateralMap[poolManager];
        // Checking the collateral requested
        _contractMapCheck(col);
        _whenNotPaused(STABLE, address(poolManager));
        // Burning the tokens will revert if there are not enough tokens in balance or if the `msg.sender`
        // does not have approval from the burner
        // A reentrancy attack is potentially possible here as state variables are written after the burn,
        // but as the `AgToken` is a protocol deployed contract, it can be trusted. Still, `AgToken` is
        // upgradeable by governance, the following could become risky in case of a governance attack
        if (burner == msg.sender) {
            agToken.burnSelf(amount, burner);
        } else {
            agToken.burnFrom(amount, burner, msg.sender);
        }
        // Getting the highest possible oracle value
        uint256 oracleValue = col.oracle.readLower(0);

        // Converting amount of agTokens in collateral and computing how much should be reimbursed to the user
        // Amount is in `BASE` and the outputted collateral amount should be in collateral base
        uint256 amountInC = (amount * col.collatBase) / oracleValue;

        uint256 fees = _computeFeeBurn(amountInC, col);

        // Computing how much of collateral can be redeemed by the user after taking fees
        // The real value is `amountInC * (BASE - fees) / BASE`, but we prefer to avoid doing multiplications
        // after divisions
        uint256 redeemInC = (amount * (BASE - fees) * col.collatBase) / (oracleValue * BASE);

        int256 stocksUsersUpdateValue = int256(amountInC);
        // For this require to fail, you need very specific conditions on `BASE`
        require(stocksUsersUpdateValue >= 0, "overflow");
        // Updating the `stocksUsers` that is the amount of collateral that was brought by users
        col.stocksUsers -= stocksUsersUpdateValue;
        emit StocksUsersUpdated(address(col.token), col.stocksUsers);
        // Computing the exact amount of fees from this transaction and accumulating it for SLPs
        _accumulateFees(amountInC - redeemInC, col);
        // If there are not enough reserves this transaction will revert and the user
        // will have to come back to the protocol with a correct amount
        col.token.safeTransferFrom(address(poolManager), dest, redeemInC);
    }

    // ============================== SLPs =========================================

    /// @notice Lets a SLP enter the protocol by adding collateral to the system in exchange of sanTokens
    /// @param user Address of the SLP to send sanTokens to
    /// @param amount Amount of collateral sent
    /// @param poolManager Address of the `PoolManager` of the required collateral
    function deposit(
        uint256 amount,
        address user,
        IPoolManager poolManager
    ) external {
        // Searching collateral data
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        _whenNotPaused(SLP, address(poolManager));
        _updateSanRate(0, col);

        // No overflow check needed for the amount since it's never casted to int and Solidity 0.8.0
        // automatically handles overflows
        col.token.safeTransferFrom(msg.sender, address(poolManager), amount);
        col.sanToken.mint(user, (amount * BASE) / col.sanRate);
    }

    /// @notice Updates variables to account for the burn of sanTokens by a SLP and gives the corresponding
    /// collateral back in exchange
    /// @param amount Amount of sanTokens burnt by the SLP
    /// @param burner Address that will burn its sanTokens
    /// @param dest Address that will receive the collateral
    /// @param poolManager Address of the `PoolManager` of the required collateral
    /// @dev The `msg.sender` should have approval to burn from the `burner` or the `msg.sender` should be the `burner`
    function withdraw(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager
    ) external {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        _whenNotPaused(SLP, address(poolManager));
        _updateSanRate(0, col);

        if (burner == msg.sender) {
            col.sanToken.burnSelf(amount, burner);
        } else {
            col.sanToken.burnFrom(amount, burner, msg.sender);
        }
        // Computing the amount of collateral to give back to the SLP depending on slippage and on the `sanRate`
        uint256 redeemInC = (amount * (BASE - col.slpData.slippage) * col.sanRate) / BASE**2;

        // If there are not enough reserves in the contract to pay the user this transaction will revert
        // It is possible to check for the reserves by calling the `getBalance` function
        col.token.safeTransferFrom(address(poolManager), dest, redeemInC);
    }
}
