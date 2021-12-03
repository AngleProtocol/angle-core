// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./IAgToken.sol";
import "./IOracle.sol";

/// @title IBondingCurve
/// @author Angle Core Team
/// @notice Interface for the `BondingCurve` contract
interface IBondingCurve {
    // ============================ User Functions =================================

    function buySoldToken(
        IAgToken _agToken,
        uint256 targetSoldTokenQuantity,
        uint256 maxAmountToPayInAgToken
    ) external;

    // ========================== Governance Functions =============================

    function changeOracle(IAgToken _agToken, IOracle _oracle) external;
}
