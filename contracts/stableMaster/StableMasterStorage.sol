// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

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
        // Base used in the collateral implementation (ERC20 decimal)
        uint256 collatBase;
        // Reference to the `SanToken` for the pool
        ISanToken sanToken;
        // Reference to the `PerpetualManager` for the pool
        IPerpetualManager perpetualManager;
        // Adress of the oracle for the change rate between
        // collateral and the corresponding stablecoin
        IOracle oracle;
        // Amount of collateral in the reserves that comes from users
        // + capital losses from HAs - capital gains of HAs
        int256 stocksUsers;
        // Exchange rate between sanToken and collateral
        uint256 sanRate;
        // Parameters for SLPs and update of the `sanRate`
        SLPData slpData;
        // All the fees parameters
        CollateralFees feeData;
    }

    // ============================ References =====================================

    /// @notice Maps a `PoolManager` contract handling a collateral for this stablecoin to the properties of the struct above
    mapping(IPoolManager => Collateral) public collateralMap;

    /// @notice List of all collateral managers
    IPoolManager[] public managerList;

    /// @notice Maps a contract to an address corresponding to the `IPoolManager` address
    /// It is typically used to avoid passing in parameters the address of the `PerpetualManager` when `PerpetualManager`
    /// is calling `StableMaster` to get information
    /// It is the Access Control equivalent for the `SanToken`, `PoolManager`, `PerpetualManager` and `FeeManager`
    /// contract associated to this `StableMaster`
    mapping(address => IPoolManager) public contractMap;

    /// @notice Reference to the `AgToken` used in this `StableMaster`
    /// This reference cannot be changed
    IAgToken public agToken;

    /// @notice Reference to the `Core` contract of the protocol
    /// This reference cannot be changed
    ICore public core;
}
