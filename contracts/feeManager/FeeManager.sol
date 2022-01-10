// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./FeeManagerStorage.sol";

/// @title FeeManager
/// @author Angle Core Team
/// @dev This contract interacts with fee parameters for a given stablecoin/collateral pair
/// @dev `FeeManager` contains all the functions that keepers can call to update parameters
/// in the `StableMaster` and `PerpetualManager` contracts
/// @dev These parameters need to be updated by keepers because they depend on variables, like
/// the collateral ratio, that are too expensive to compute each time transactions that would need
/// it occur
contract FeeManager is FeeManagerStorage, IFeeManagerFunctions, AccessControl, Initializable {
    /// @notice Role for `PoolManager` only
    bytes32 public constant POOLMANAGER_ROLE = keccak256("POOLMANAGER_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Deploys the `FeeManager` contract for a pair stablecoin/collateral
    /// @param _poolManager `PoolManager` contract handling the collateral
    /// @dev The `_poolManager` address is used to grant the correct role. It does not need to be stored by the
    /// contract
    /// @dev There is no need to do a zero address check on the `_poolManager` as if the zero address is passed
    /// the function will revert when trying to fetch the `StableMaster`
    constructor(IPoolManager _poolManager) {
        stableMaster = IStableMaster(_poolManager.stableMaster());
        // Once a `FeeManager` contract has been initialized with a `PoolManager` contract, this
        // reference cannot be modified
        _setupRole(POOLMANAGER_ROLE, address(_poolManager));

        _setRoleAdmin(POOLMANAGER_ROLE, POOLMANAGER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, POOLMANAGER_ROLE);
    }

    /// @notice Initializes the governor and guardian roles of the contract as well as the reference to
    /// the `perpetualManager` contract
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Guardian address of the protocol
    /// @param _perpetualManager `PerpetualManager` contract handling the perpetuals of the pool
    /// @dev `GUARDIAN_ROLE` can then directly be granted or revoked by the corresponding `PoolManager`
    /// As `POOLMANAGER_ROLE` is admin of `GUARDIAN_ROLE`, it corresponds to the intended behaviour of roles
    function deployCollateral(
        address[] memory governorList,
        address guardian,
        address _perpetualManager
    ) external override onlyRole(POOLMANAGER_ROLE) initializer {
        for (uint256 i = 0; i < governorList.length; i++) {
            _grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        _grantRole(GUARDIAN_ROLE, guardian);
        perpetualManager = IPerpetualManager(_perpetualManager);
    }

    // ============================ `StableMaster` =================================

    /// @notice Updates the SLP and Users fees associated to the pair stablecoin/collateral in
    /// the `StableMaster` contract
    /// @dev This function updates:
    /// 	-	`bonusMalusMint`: part of the fee induced by a user minting depending on the collateral ratio
    ///                   In normal times, no fees are taken for that, and so this fee should be equal to `BASE_PARAMS`
    ///		-	`bonusMalusBurn`: part of the fee induced by a user burning depending on the collateral ratio
    ///		-	Slippage: what's given to SLPs compared with their claim when they exit
    ///		-	SlippageFee: that is the portion of fees that is put aside because the protocol
    ///         is not well collateralized
    /// @dev `bonusMalusMint` and `bonusMalusBurn` allow governance to add penalties or bonuses for users minting
    /// and burning in some situations of collateral ratio. These parameters are multiplied to the fee amount depending
    /// on the hedge ratio by Hedging Agents to get the exact fee induced to the users
    function updateUsersSLP() external override {
        // Computing the collateral ratio, expressed in `BASE_PARAMS`
        uint256 collatRatio = stableMaster.getCollateralRatio();
        // Computing the fees based on this collateral ratio
        uint64 bonusMalusMint = _piecewiseLinearCollatRatio(collatRatio, xBonusMalusMint, yBonusMalusMint);
        uint64 bonusMalusBurn = _piecewiseLinearCollatRatio(collatRatio, xBonusMalusBurn, yBonusMalusBurn);
        uint64 slippage = _piecewiseLinearCollatRatio(collatRatio, xSlippage, ySlippage);
        uint64 slippageFee = _piecewiseLinearCollatRatio(collatRatio, xSlippageFee, ySlippageFee);

        emit UserAndSLPFeesUpdated(collatRatio, bonusMalusMint, bonusMalusBurn, slippage, slippageFee);
        stableMaster.setFeeKeeper(bonusMalusMint, bonusMalusBurn, slippage, slippageFee);
    }

    // ============================= PerpetualManager ==============================

    /// @notice Updates HA fees associated to the pair stablecoin/collateral in the `PerpetualManager` contract
    /// @dev This function updates:
    ///     - The part of the fee taken from HAs when they open a perpetual or add collateral in it. This allows
    ///        governance to add penalties or bonuses in some occasions to HAs opening their perpetuals
    ///     - The part of the fee taken from the HA when they withdraw collateral from a perpetual. This allows
    ///       governance to add penalty or bonuses in some occasions to HAs closing their perpetuals
    /// @dev Penalties or bonuses for HAs should almost never be used
    /// @dev In the `PerpetualManager` contract, these parameters are multiplied to the fee amount depending on the HA
    /// hedge ratio to get the exact fee amount for HAs
    /// @dev For the moment, these parameters do not depend on the collateral ratio, and they are just an extra
    /// element that governance can play on to correct fees taken for HAs
    function updateHA() external override {
        emit HaFeesUpdated(haFeeDeposit, haFeeWithdraw);
        perpetualManager.setFeeKeeper(haFeeDeposit, haFeeWithdraw);
    }

    // ============================= Governance ====================================

    /// @notice Sets the x (i.e. thresholds of collateral ratio) array / y (i.e. value of fees at threshold)-array
    /// for users minting, burning, for SLPs withdrawal slippage or for the slippage fee when updating
    /// the exchange rate between sanTokens and collateral
    /// @param xArray New collateral ratio thresholds (in ascending order)
    /// @param yArray New fees or values for the parameters at thresholds
    /// @param typeChange Type of parameter to change
    /// @dev For `typeChange = 1`, `bonusMalusMint` fees are updated
    /// @dev For `typeChange = 2`, `bonusMalusBurn` fees are updated
    /// @dev For `typeChange = 3`, `slippage` values are updated
    /// @dev For other values of `typeChange`, `slippageFee` values are updated
    function setFees(
        uint256[] memory xArray,
        uint64[] memory yArray,
        uint8 typeChange
    ) external override onlyRole(GUARDIAN_ROLE) {
        require(xArray.length == yArray.length && yArray.length > 0, "5");
        for (uint256 i = 0; i <= yArray.length - 1; i++) {
            if (i > 0) {
                require(xArray[i] > xArray[i - 1], "7");
            }
        }
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
            _checkSlippageCompatibility();
            emit SlippageUpdated(xSlippage, ySlippage);
        } else {
            xSlippageFee = xArray;
            ySlippageFee = yArray;
            _checkSlippageCompatibility();
            emit SlippageFeeUpdated(xSlippageFee, ySlippageFee);
        }
    }

    /// @notice Sets the extra fees that can be used when HAs deposit or withdraw collateral from the
    /// protocol
    /// @param _haFeeDeposit New parameter to modify deposit fee for HAs
    /// @param _haFeeWithdraw New parameter to modify withdraw fee for HAs
    function setHAFees(uint64 _haFeeDeposit, uint64 _haFeeWithdraw) external override onlyRole(GUARDIAN_ROLE) {
        haFeeDeposit = _haFeeDeposit;
        haFeeWithdraw = _haFeeWithdraw;
    }

    /// @notice Helps to make sure that the `slippageFee` and the `slippage` will in most situations be compatible
    /// with one another
    /// @dev Whenever the `slippageFee` is not null, the `slippage` should be non null, as otherwise, there would be
    /// an opportunity cost to increase the collateral ratio to make the `slippage` non null and collect the fees
    /// that have been left aside
    /// @dev This function does not perform an exhaustive check around the fact that whenever the `slippageFee`
    /// is not null the `slippage` is not null neither. It simply checks that each positive value in the `ySlippageFee` array
    /// corresponds to a positive value of the `slippage`
    /// @dev The protocol still relies on governance to make sure that this condition is always verified, this function
    /// is just here to eliminate potentially extreme errors
    function _checkSlippageCompatibility() internal view {
        // We need this `if` condition because when this function is first called after contract deployment, the length
        // of the two arrays is zero
        if (xSlippage.length >= 1 && xSlippageFee.length >= 1) {
            for (uint256 i = 0; i <= ySlippageFee.length - 1; i++) {
                if (ySlippageFee[i] > 0) {
                    require(ySlippageFee[i] <= BASE_PARAMS_CASTED, "37");
                    require(_piecewiseLinearCollatRatio(xSlippageFee[i], xSlippage, ySlippage) > 0, "38");
                }
            }
        }
    }

    /// @notice Computes the value of a linear by part function at a given point
    /// @param x Point of the function we want to compute
    /// @param xArray List of breaking points (in ascending order) that define the linear by part function
    /// @param yArray List of values at breaking points (not necessarily in ascending order)
    /// @dev The evolution of the linear by part function between two breaking points is linear
    /// @dev Before the first breaking point and after the last one, the function is constant with a value
    /// equal to the first or last value of the `yArray`
    /// @dev The reason for having a function that is different from what's in the `FunctionUtils` contract is that
    /// here the values in `xArray` can be greater than `BASE_PARAMS` meaning that there is a non negligeable risk that
    /// the product between `yArray` and `xArray` values overflows
    function _piecewiseLinearCollatRatio(
        uint256 x,
        uint256[] storage xArray,
        uint64[] storage yArray
    ) internal view returns (uint64 y) {
        if (x >= xArray[xArray.length - 1]) {
            return yArray[xArray.length - 1];
        } else if (x <= xArray[0]) {
            return yArray[0];
        } else {
            uint256 lower;
            uint256 upper = xArray.length - 1;
            uint256 mid;
            while (upper - lower > 1) {
                mid = lower + (upper - lower) / 2;
                if (xArray[mid] <= x) {
                    lower = mid;
                } else {
                    upper = mid;
                }
            }
            uint256 yCasted;
            if (yArray[upper] > yArray[lower]) {
                yCasted =
                    yArray[lower] +
                    ((yArray[upper] - yArray[lower]) * (x - xArray[lower])) /
                    (xArray[upper] - xArray[lower]);
            } else {
                yCasted =
                    yArray[lower] -
                    ((yArray[lower] - yArray[upper]) * (x - xArray[lower])) /
                    (xArray[upper] - xArray[lower]);
            }
            // There is no problem with this cast as `y` was initially a `uint64` and we divided a `uint256` with a `uint256`
            // that is greater
            y = uint64(yCasted);
        }
    }
}
