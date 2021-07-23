// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./FeeManagerStorage.sol";

/// @title FeeManager
/// @author Angle Core Team
/// @dev This contract interacts with fee parameters for a given stablecoin/collateral pair
/// @dev `FeeManager` contains all the functions that keepers can call to update parameters
/// (most often fee parameters) in the `StableMaster` and `PerpetualManager` contracts
/// @dev These parameters need to be updated by keepers because they depend on variables, like
/// the collateral ratio, that are too expensive to compute each time
contract FeeManager is FeeManagerStorage, IFeeManager, AccessControl, Initializable {
    /// @notice Role for `PoolManager` only
    bytes32 public constant POOLMANAGER_ROLE = keccak256("POOLMANAGER_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Deploys the `FeeManager` contract for a pair stablecoin/collateral
    /// @param _poolManager `PoolManager` contract handling the collateral
    /// @param _perpetualManager `PerpetualManager` contract handling the perpetuals of the pool
    /// @dev The `_poolManager` address is used to grant the correct role. It does not need to be stored by the
    /// contract
    /// @dev There is no need to do a zero address check on the `_poolManager` as if the zero address is passed
    /// the function will revert when trying to fetch the `StableMaster`
    constructor(IPoolManager _poolManager, IPerpetualManager _perpetualManager) {
        require(address(_perpetualManager) != address(0), "zero address");
        stableMaster = IStableMaster(_poolManager.stableMaster());
        perpetualManager = _perpetualManager;
        // Once a `FeeManager` contract has been initialized with a `PoolManager` contract, this
        // reference cannot be modified
        _setupRole(POOLMANAGER_ROLE, address(_poolManager));

        _setRoleAdmin(POOLMANAGER_ROLE, POOLMANAGER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, POOLMANAGER_ROLE);
    }

    /// @notice Initializes the governor and guardian roles of the contract
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Guardian address of the protocol
    /// @dev `GUARDIAN_ROLE` can then directly be granted or revoked by the corresponding `PoolManager`
    function deployCollateral(address[] memory governorList, address guardian)
        external
        override
        onlyRole(POOLMANAGER_ROLE)
        initializer
    {
        for (uint256 i = 0; i < governorList.length; i++) {
            grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        grantRole(GUARDIAN_ROLE, guardian);
    }

    // ============================ `StableMaster` =================================

    /// @notice Updates the SLP and Users fees associated to the pair stablecoin/collateral in
    /// the `StableMaster` contract
    /// @dev This function updates:
    /// 	-	`bonusMalusMint`: part of the fee induced by a user minting depending on the collateral ratio
    ///                   In normal times, no fees are taken for that, and so this fee should be equal to BASE
    ///		-	`bonusMalusBurn`: part of the fee induced by a user burning depending on the collateral ratio
    ///		-	Slippage: what's given to SLPs compared with their claim when they exit
    ///		-	SlippageFee: that is the portion of fees that is put aside because the protocol
    ///         is not well collateralized
    /// @dev `bonusMalusMint` and `bonusMalusBurn` allow governance to add penalties or bonuses for users minting
    /// and burning in some situations of collateral ratio. These parameters are multiplied to the fee amount depending
    /// on coverage by Hedging Agents to get the exact fee induced to the users
    function updateUsersSLP() external {
        // Computing the collateral ratio
        uint256 collatRatio = stableMaster.getCollateralRatio();
        // Computing the fees based on this collateral ratio
        uint256 bonusMalusMint = _piecewiseLinear(collatRatio, xBonusMalusMint, yBonusMalusMint);
        uint256 bonusMalusBurn = _piecewiseLinear(collatRatio, xBonusMalusBurn, yBonusMalusBurn);
        uint256 slippage = _piecewiseLinear(collatRatio, xSlippage, ySlippage);
        uint256 slippageFee = _piecewiseLinear(collatRatio, xSlippageFee, ySlippageFee);

        emit UserAndSLPFeesUpdated(collatRatio, bonusMalusMint, bonusMalusBurn, slippage, slippageFee);
        stableMaster.setFeeKeeper(bonusMalusMint, bonusMalusBurn, slippage, slippageFee);
    }

    // ============================= PerpetualManager ==============================

    /// @notice Updates HA fees associated to the pair stablecoin/collateral in the `PerpetualManager` contract
    /// @dev This function updates:
    ///     - The part of the fee taken from HAs when they create a perpetual or add collateral in it. This allows
    ///        governance to add penalties or bonuses in some occasions to HAs opening their perpetuals
    ///     - The part of the fee taken from the HA when they withdraw collateral from a perpetual. This allows
    ///       governance to add penalty or bonuses in some occasions to HAs closing their perpetuals
    /// @dev Penalties or bonuses for HAs should almost never be used
    /// @dev In the `PerpetualManager` contract, these parameters are multiplied to the fee amount depending on the HA
    /// coverage to get the exact fee amount for HAs
    /// @dev For the moment, these parameters do not depend on the collateral ratio, and they are just an extra
    /// element that governance can play on to correct fees taken for HAs
    function updateHA() external {
        emit HaFeesUpdated(haFeeDeposit, haFeeWithdraw);
        perpetualManager.setFeeKeeper(haFeeDeposit, haFeeWithdraw);
    }

    // ============================= Governance ====================================

    /// @notice Sets the x(ie thresholds of collateral ratio) array / y(ie value of fees at threshold)-array
    /// for users minting, burning, for SLPs withdrawal slippage or for the slippage fee when updating
    /// the exchange rate between sanTokens and collateral
    /// @param xArray New collateral ratio thresholds (in ascending order)
    /// @param yArray New fees or values for the parameters at thresholds
    /// @param typeChange Type of parameter to change
    /// @dev For `typeChange = 1`, `bonusMalusMint` fees are updated
    /// @dev For `typeChange = 2`, `bonusMalusBurn` fees are updated
    /// @dev For `typeChange = 3`, `Slippage` values are updated
    /// @dev For other values of `typeChange`, `SlippageFee` values are updated
    function setFees(
        uint256[] memory xArray,
        uint256[] memory yArray,
        uint256 typeChange
    ) external onlyRole(GUARDIAN_ROLE) onlyCompatibleInputArrays(xArray, yArray, false) {
        if (typeChange == 1) {
            xBonusMalusMint = xArray;
            yBonusMalusMint = yArray;
            emit FeeMintUpdated(xBonusMalusMint, yBonusMalusMint);
        } else if (typeChange == 2) {
            xBonusMalusBurn = xArray;
            yBonusMalusBurn = yArray;
            emit FeeBurnUpdated(xBonusMalusBurn, yBonusMalusBurn);
        } else if (typeChange == 3) {
            xSlippage = xArray;
            ySlippage = yArray;
            emit SlippageUpdated(xSlippage, ySlippage);
        } else {
            xSlippageFee = xArray;
            ySlippageFee = yArray;
            emit SlippageFeeUpdated(xSlippageFee, ySlippageFee);
        }
    }

    /// @notice Sets the extra fees that can be used when HAs deposit or withdraw collateral from the
    /// protocol
    /// @param _haFeeDeposit New parameter to modify deposit fee for HAs
    /// @param _haFeeWithdraw New parameter to modify withdraw fee for HAs
    function setHAFees(uint256 _haFeeDeposit, uint256 _haFeeWithdraw) external onlyRole(GUARDIAN_ROLE) {
        haFeeDeposit = _haFeeDeposit;
        haFeeWithdraw = _haFeeWithdraw;
    }
}
