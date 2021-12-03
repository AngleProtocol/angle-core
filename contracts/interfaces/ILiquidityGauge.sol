// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

interface ILiquidityGauge {
    // solhint-disable-next-line
    function deposit_reward_token(address _rewardToken, uint256 _amount) external;
}
