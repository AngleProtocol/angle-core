// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./IAgToken.sol";
import "./IOracle.sol";

/// @title IBondingCurve
/// @author Angle Core Team
/// @notice Interface for the `BondingCurve` contract
interface IBondingCurve {
    // ============================ User Functions =================================

    function buySoldToken(IAgToken _agToken, uint256 targetANGLEQuantity) external;

    // ========================== Governance Functions =============================

    function changeOracle(IAgToken _agToken, IOracle _oracle) external;
}
