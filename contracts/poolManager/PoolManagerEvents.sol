// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "../external/AccessControlUpgradeable.sol";

import "../interfaces/IFeeManager.sol";
import "../interfaces/IPoolManager.sol";
import "../interfaces/ISanToken.sol";
import "../interfaces/IPerpetualManager.sol";
import "../interfaces/IStableMaster.sol";
import "../interfaces/IStrategy.sol";

import "../utils/FunctionUtils.sol";

/// @title PoolManagerEvents
/// @author Angle Core Team
/// @notice The `PoolManager` contract corresponds to a collateral pool of the protocol for a stablecoin,
/// it manages a single ERC20 token. It is responsible for interacting with the strategies enabling the protocol
/// to get yield on its collateral
/// @dev This contract contains all the events of the `PoolManager` Contract
contract PoolManagerEvents {
    event FeesDistributed(uint256 amountDistributed);

    event Recovered(address indexed token, address indexed to, uint256 amount);

    event StrategyAdded(address indexed strategy, uint256 debtRatio);

    event StrategyRevoked(address indexed strategy);

    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 debtPayment,
        uint256 totalDebt
    );
}
