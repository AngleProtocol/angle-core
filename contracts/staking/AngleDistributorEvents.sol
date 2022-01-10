// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

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
  event Recovered(
    address indexed tokenAddress,
    address indexed to,
    uint256 amount
  );
  event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
  event GaugeControllerUpdated(address indexed _controller);
  event DistributionsToggled(bool _distributionsOn);
  event RewardDistributed(address indexed gaugeAddr, uint256 rewardTally);
  event DelegateGaugeUpdated(address indexed _delegateGauge);
}
