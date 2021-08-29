// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

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
    /// @param core_ Address of the `Core` contract handling all the different `StableMaster` contracts
    function initialize(address core_) external zeroCheck(core_) initializer {
        __AccessControl_init();
        // Access control
        _core = ICore(core_);
        _setupRole(CORE_ROLE, core_);
        // `Core` is admin of all roles
        _setRoleAdmin(CORE_ROLE, CORE_ROLE);
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
    /// @param minStableAmount Minimum amount of stablecoins the user wants to get with this transaction
    /// @dev This function works as a swap from a user perspective from collateral to stablecoins
    /// @dev It is impossible to mint tokens and to have them sent to the zero address: there
    /// would be an issue with the `_mint` function called by the `AgToken` contract
    /// @dev The parameter `minStableAmount` serves as a slippage protection for users
    function mint(
        uint256 amount,
        address user,
        IPoolManager poolManager,
        uint256 minStableAmount
    ) external {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        // Checking if the contract is paused for this agent
        _whenNotPaused(STABLE, address(poolManager));

        // No overflow check are needed for the amount since it's never casted to `int` and Solidity 0.8.0
        // automatically handles overflows
        col.token.safeTransferFrom(msg.sender, address(poolManager), amount);

        // Getting a quote for the amount of stablecoins to issue
        // We read the lowest oracle value we get for this collateral/stablecoin pair: it's the one
        // that is most at the advantage of the protocol
        // Decimals are handled directly in the oracle contract
        uint256 amountForUserInStable = col.oracle.readQuoteLower(amount);

        // Getting the fees paid for this transaction, expressed in `BASE_PARAMS`
        // Floor values are taken for fees computation, as what is earned by users is lost by SLP
        // when calling `_updateSanRate` and vice versa
        uint256 fees = _computeFeeMint(amountForUserInStable, col);

        // Computing the net amount that will be taken into account for this user by deducing fees
        amountForUserInStable = (amountForUserInStable * (BASE_PARAMS - fees)) / BASE_PARAMS;
        // Checking if the user got more stablecoins than the least amount specified in the parameters of the
        // function
        require(amountForUserInStable >= minStableAmount, "too big slippage");

        // Updating the `stocksUsers` for this collateral, that is the amount of collateral that was
        // brought by users
        col.stocksUsers += amountForUserInStable;
        // Checking if stablecoins can still be issued using this collateral type
        require(col.stocksUsers <= col.feeData.capOnStableMinted, "too many stablecoins issued");
        emit StocksUsersUpdated(address(poolManager), col.stocksUsers);

        // Distributing the fees taken to SLPs
        // The `fees` variable computed above is a proportion expressed in `BASE_PARAMS`.
        // To compute the amount of fees in collateral value, we can directly use the `amount` of collateral
        // entered by the user
        // Not all the fees are distributed to SLPs, a portion determined by `col.slpData.feesForSLPs` goes to surplus
        _updateSanRate((amount * fees * col.slpData.feesForSLPs) / (BASE_PARAMS**2), col);

        // Minting
        agToken.mint(user, amountForUserInStable);
    }

    /// @notice Updates variables to take the burn of agTokens (stablecoins) into account, computes transaction
    /// fees and gives collateral from the `PoolManager` in exchange for that
    /// @param amount Amount of stable asset burnt
    /// @param burner Address from which the agTokens will be burnt
    /// @param dest Address where collateral is going to be
    /// @param poolManager Collateral type requested by the user burning
    /// @param minCollatAmount Minimum
    /// @dev The `msg.sender` should have approval to burn from the `burner` or the `msg.sender` should be the `burner`
    /// @dev If there are not enough reserves this transaction will revert and the user will have to come back to the
    /// protocol with a correct amount. Checking for the reserves currently available in the `PoolManager`
    /// is something that should be handled by the front interacting with this contract
    /// @dev In case there are not enough reserves, strategies should be harvested or their debt ratios should be adjusted
    /// by governance to make sure that users, HAs or SLPs withdrawing always have free collateral they can use
    /// @dev From a user perspective, this function is equivalent to a swap from stablecoins to collateral
    function burn(
        uint256 amount,
        address burner,
        address dest,
        IPoolManager poolManager,
        uint256 minCollatAmount
    ) external {
        // Searching collateral data
        Collateral storage col = collateralMap[poolManager];
        // Checking the collateral requested
        _contractMapCheck(col);
        _whenNotPaused(STABLE, address(poolManager));

        // If the amount is such that `stocksUsers` can become negative, then HAs and users actions should be paused
        // This is likely to happen if users mint using one collateral type and in volume redeem another collateral type
        // In this situation, governance should rapidly react to rebalance the `stocksUsers` between the concerned
        // collateral types, or at least what is stored in the reserves through the `recoverERC20` function followed by a swap
        // and then a transfer
        if (amount > col.stocksUsers) {
            _pause(keccak256(abi.encodePacked(STABLE, address(poolManager))));
            // Pausing entry (and exits for HAs)
            col.perpetualManager.pause();
            return;
        }

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
        uint256 oracleValue = col.oracle.readUpper();

        // Converting amount of agTokens in collateral and computing how much should be reimbursed to the user
        // Amount is in `BASE_TOKENS` and the outputted collateral amount should be in collateral base
        uint256 amountInC = (amount * col.collatBase) / oracleValue;

        // Computing how much of collateral can be redeemed by the user after taking fees
        // The value of the fees here is `_computeFeeBurn(amount,col)` (it is a proportion expressed in `BASE_PARAMS`)
        // The real value of what can be redeemed by the user is `amountInC * (BASE_PARAMS - fees) / BASE_PARAMS`,
        // but we prefer to avoid doing multiplications after divisions
        uint256 redeemInC = (amount * (BASE_PARAMS - _computeFeeBurn(amount, col)) * col.collatBase) /
            (oracleValue * BASE_PARAMS);
        require(redeemInC >= minCollatAmount, "too big slippage");

        // Updating the `stocksUsers` that is the amount of collateral that was brought by users
        col.stocksUsers -= amount;
        emit StocksUsersUpdated(address(poolManager), col.stocksUsers);

        // Computing the exact amount of fees from this transaction and accumulating it for SLPs
        _updateSanRate(((amountInC - redeemInC) * col.slpData.feesForSLPs) / BASE_PARAMS, col);

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

        // No overflow check needed for the amount since it's never casted to int and Solidity versions above 0.8.0
        // automatically handle overflows
        col.token.safeTransferFrom(msg.sender, address(poolManager), amount);
        col.sanToken.mint(user, (amount * BASE_TOKENS) / col.sanRate);
    }

    /// @notice Updates variables to account for the burn of sanTokens by a SLP and gives the corresponding
    /// collateral back in exchange
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
        uint256 redeemInC = (amount * (BASE_PARAMS - col.slpData.slippage) * col.sanRate) / (BASE_TOKENS * BASE_PARAMS);

        col.token.safeTransferFrom(address(poolManager), dest, redeemInC);
    }
}
