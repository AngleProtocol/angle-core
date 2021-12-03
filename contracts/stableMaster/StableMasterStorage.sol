// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./StableMasterEvents.sol";

/// @title StableMasterStorage
/// @author Angle Core Team
/// @notice `StableMaster` is the contract handling all the collateral types accepted for a given stablecoin
/// It does all the accounting and is the point of entry in the protocol for stable holders and seekers as well as SLPs
/// @dev This file contains all the variables and parameters used in the `StableMaster` contract
contract StableMasterStorage is StableMasterEvents, FunctionUtils {
    // All the details about a collateral that are going to be stored in `StableMaster`
    struct Collateral {
        // Interface for the token accepted by the underlying `PoolManager` contract
        IERC20 token;
        // Reference to the `SanToken` for the pool
        ISanToken sanToken;
        // Reference to the `PerpetualManager` for the pool
        IPerpetualManager perpetualManager;
        // Adress of the oracle for the change rate between
        // collateral and the corresponding stablecoin
        IOracle oracle;
        // Amount of collateral in the reserves that comes from users
        // converted in stablecoin value. Updated at minting and burning.
        // A `stocksUsers` of 10 for a collateral type means that overall the balance of the collateral from users
        // that minted/burnt stablecoins using this collateral is worth 10 of stablecoins
        uint256 stocksUsers;
        // Exchange rate between sanToken and collateral
        uint256 sanRate;
        // Base used in the collateral implementation (ERC20 decimal)
        uint256 collatBase;
        // Parameters for SLPs and update of the `sanRate`
        SLPData slpData;
        // All the fees parameters
        MintBurnData feeData;
    }

    // ============================ Variables and References =====================================

    /// @notice Maps a `PoolManager` contract handling a collateral for this stablecoin to the properties of the struct above
    mapping(IPoolManager => Collateral) public collateralMap;

    /// @notice Reference to the `AgToken` used in this `StableMaster`
    /// This reference cannot be changed
    IAgToken public agToken;

    // Maps a contract to an address corresponding to the `IPoolManager` address
    // It is typically used to avoid passing in parameters the address of the `PerpetualManager` when `PerpetualManager`
    // is calling `StableMaster` to get information
    // It is the Access Control equivalent for the `SanToken`, `PoolManager`, `PerpetualManager` and `FeeManager`
    // contracts associated to this `StableMaster`
    mapping(address => IPoolManager) internal _contractMap;

    // List of all collateral managers
    IPoolManager[] internal _managerList;

    // Reference to the `Core` contract of the protocol
    ICore internal _core;
}
