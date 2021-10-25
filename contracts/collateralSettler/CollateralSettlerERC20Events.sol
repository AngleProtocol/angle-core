// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../external/AccessControl.sol";

import "../interfaces/IAgToken.sol";
import "../interfaces/ICollateralSettler.sol";
import "../interfaces/IPoolManager.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IPerpetualManager.sol";
import "../interfaces/ISanToken.sol";
import "../interfaces/IStableMaster.sol";

/// @title CollateralSettlerERC20Events
/// @author Angle Core Team
/// @notice All the events used in `CollateralSettlerERC20` contract
contract CollateralSettlerERC20Events {
    event CollateralSettlerInit(address indexed poolManager, address indexed angle, uint256 claimTime);

    event SettlementTriggered(uint256 _amountToRedistribute);

    event UserClaimGovUpdated(uint256 userClaimGov);

    event UserClaimUpdated(uint256 userClaim);

    event LPClaimGovUpdated(uint256 lpClaimGov);

    event LPClaimUpdated(uint256 lpClaim);

    event AmountToRedistributeAnnouncement(
        uint256 baseAmountToUserGov,
        uint256 baseAmountToUser,
        uint256 baseAmountToLpGov,
        uint256 baseAmountToLp,
        uint256 amountToRedistribute
    );

    event AmountRedistributeUpdated(uint256 amountRedistribute);

    event ProportionalRatioGovUpdated(uint64 proportionalRatioGovUser, uint64 proportionalRatioGovLP);

    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);
}
