// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../external/AccessControl.sol";

import "../interfaces/IRewardsDistributor.sol";
import "../interfaces/IStakingRewards.sol";

/// @title StakingRewardsEvents
/// @author Angle Core Team
/// @notice All the events used in `StakingRewards` contract
contract StakingRewardsEvents {
    event RewardAdded(uint256 reward);

    event Staked(address indexed user, uint256 amount);

    event Withdrawn(address indexed user, uint256 amount);

    event RewardPaid(address indexed user, uint256 reward);

    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);

    event RewardsDistributionUpdated(address indexed _rewardsDistribution);
}
