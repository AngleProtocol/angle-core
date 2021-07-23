// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/IERC165Upgradeable.sol";

import "./IFeeManager.sol";
import "./IOracle.sol";

/// @title Interface of the contract managing perpetuals
/// @author Angle Core Team
/// @dev Front interface, meaning only user-facing functions
interface IPerpetualManagerFront {
    // ========================= External View Functions =============================

    function getCashOutAmount(uint256 perpetualID, uint256 rate) external view returns (uint256, uint256);

    // ========================= ERC721 =============================

    function balanceOf(address owner) external view returns (uint256 balance);

    function ownerOf(uint256 perpetualID) external view returns (address owner);

    function safeTransferFrom(
        address from,
        address to,
        uint256 perpetualID
    ) external;

    function transferFrom(
        address from,
        address to,
        uint256 perpetualID
    ) external;

    function approve(address to, uint256 perpetualID) external;

    function getApproved(uint256 perpetualID) external view returns (address operator);

    function setApprovalForAll(address operator, bool _approved) external;

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function safeTransferFrom(
        address from,
        address to,
        uint256 perpetualID,
        bytes calldata data
    ) external;
}

/// @title Interface of the contract managing perpetuals
/// @author Angle Core Team
/// @dev This interface does not contain user facing functions, it just has functions that are
/// interacted with in other parts of the protocol
interface IPerpetualManager is IAccessControlUpgradeable, IERC165Upgradeable {
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

    function setFeeKeeper(uint256 feeDeposit, uint256 feesWithdraw) external;

    // =============================== StableMaster ================================

    function setOracle(IOracle _oracle) external;

    function getCoverageInfo() external view returns (uint256, uint256);
}
