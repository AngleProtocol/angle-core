// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IGaugeController.sol";
import "../interfaces/ILiquidityGauge.sol";
import "../interfaces/IAngleMiddlemanGauge.sol";
import "../interfaces/IStakingRewards.sol";

import "../external/AccessControlUpgradeable.sol";

/// @title AngleDistributorEvents
/// @author Angle Core Team
/// @notice All the events used in `AngleDistributor` contract
contract AngleDistributorEvents {
    event DelegateGaugeUpdated(address indexed _gaugeAddr, address indexed _delegateGauge);
    event DistributionsToggled(bool _distributionsOn);
    event GaugeControllerUpdated(address indexed _controller);
    event GaugeToggled(address indexed gaugeAddr, bool newStatus);
    event InterfaceKnownToggled(address indexed _delegateGauge, bool _isInterfaceKnown);
    event RateUpdated(uint256 _newRate);
    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);
    event RewardDistributed(address indexed gaugeAddr, uint256 rewardTally);
    event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
}
