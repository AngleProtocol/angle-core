// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

/// @title IStakingRewards
/// @author Angle Core Team
/// @notice Interface for the staking rewards contract that interact with the `RewardsDistributor` contract
interface IStakingRewards {
    function notifyRewardAmount(uint256 reward) external;

    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 tokenAmount
    ) external;

    function setNewRewardsDistributor(address newRewardsDistributor) external;
}
