// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "./BaseStrategy.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../interfaces/IGenericLender.sol";
import "../interfaces/IOracle.sol";

/// @title StrategyEvents
/// @author Angle Core Team
/// @notice Events used in `Strategy` contracts
contract StrategyEvents {
    event AddLender(address indexed lender);

    event RemoveLender(address indexed lender);
}
