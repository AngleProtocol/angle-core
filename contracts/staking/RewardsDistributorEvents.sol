// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../external/AccessControl.sol";

import "../interfaces/IRewardsDistributor.sol";
import "../interfaces/IStakingRewards.sol";

/// @title RewardsDistributorEvents
/// @author Angle Core Team
/// @notice All the events used in `RewardsDistributor` contract
contract RewardsDistributorEvents {
    event Dripped(address indexed _caller, uint256 _amount, address _stakingContract);

    event RewardTokenWithdrawn(uint256 _amount);

    event FrequencyUpdated(uint256 _frequency, address indexed _stakingContract);

    event IncentiveUpdated(uint256 _incentiveAmount, address indexed _stakingContract);

    event AmountToDistributeUpdated(uint256 _amountToDistribute, address indexed _stakingContract);

    event DurationUpdated(uint256 _duration, address indexed _stakingContract);

    event NewStakingContract(address indexed _stakingContract);

    event DeletedStakingContract(address indexed stakingContract);

    event NewRewardsDistributor(address indexed newRewardsDistributor);
}
