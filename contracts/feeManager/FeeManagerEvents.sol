// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IFeeManager.sol";
import "../interfaces/IPoolManager.sol";
import "../interfaces/IStableMaster.sol";
import "../interfaces/IPerpetualManager.sol";

import "../utils/FunctionUtils.sol";

/// @title FeeManagerEvents
/// @author Angle Core Team
/// @dev This file contains all the events that are triggered by the `FeeManager` contract
contract FeeManagerEvents {
    event UserAndSLPFeesUpdated(
        uint256 _collatRatio,
        uint256 _bonusMalusMint,
        uint256 _bonusMalusBurn,
        uint256 _slippage,
        uint256 _slippageFee
    );

    event FeeMintUpdated(uint256[] _xBonusMalusMint, uint256[] _yBonusMalusMint);

    event FeeBurnUpdated(uint256[] _xBonusMalusBurn, uint256[] _yBonusMalusBurn);

    event SlippageUpdated(uint256[] _xSlippage, uint256[] _ySlippage);

    event SlippageFeeUpdated(uint256[] _xSlippageFee, uint256[] _ySlippageFee);

    event HaFeesUpdated(uint256 _haFeeDeposit, uint256 _haFeeWithdraw);
}
