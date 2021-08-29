// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./IERC721.sol";
import "./IFeeManager.sol";
import "./IOracle.sol";

/// @title Interface of the contract managing perpetuals
/// @author Angle Core Team
/// @dev Front interface, meaning only user-facing functions
interface IPerpetualManagerFront is IERC721 {
    function createPerpetual(
        address owner,
        uint256 amountBrought,
        uint256 amountCommitted,
        uint256 maxOracleRate
    ) external returns (uint256 perpetualID);

    function cashOutPerpetual(
        uint256 perpetualID,
        address to,
        uint256 minOracleRate
    ) external;

    function addToPerpetual(uint256 perpetualID, uint256 amount) external;

    function removeFromPerpetual(
        uint256 perpetualID,
        uint256 amount,
        address to
    ) external;

    function liquidatePerpetuals(uint256[] memory perpetualIDs) external;

    function forceCashOutPerpetuals(uint256[] memory perpetualIDs) external;

    // ========================= External View Functions =============================

    function getCashOutAmount(uint256 perpetualID, uint256 rate) external view returns (uint256, uint256);

    function isApprovedOrOwner(address spender, uint256 perpetualID) external view returns (bool);
}

/// @title Interface of the contract managing perpetuals
/// @author Angle Core Team
/// @dev This interface does not contain user facing functions, it just has functions that are
/// interacted with in other parts of the protocol
interface IPerpetualManagerFunctions is IAccessControl {
    // ================================= Governance ================================

    function deployCollateral(
        address[] memory governorList,
        address guardian,
        IFeeManager feeManager
    ) external;

    function setFeeManager(IFeeManager feeManager_) external;

    function pause() external;

    function unpause() external;

    // ==================================== Keepers ================================

    function setFeeKeeper(uint64 feeDeposit, uint64 feesWithdraw) external;

    // =============================== StableMaster ================================

    function setOracle(IOracle _oracle) external;
}

/// @title IPerpetualManager
/// @author Angle Core Team
/// @notice Previous interface with additionnal getters for public variables
interface IPerpetualManager is IPerpetualManagerFunctions {
    function poolManager() external view returns (address);

    function oracle() external view returns (address);

    function targetHACoverage() external view returns (uint64);

    function totalCoveredAmount() external view returns (uint256);
}
