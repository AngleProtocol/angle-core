// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../external/AccessControl.sol";

import "../interfaces/IAgToken.sol";
import "../interfaces/IBondingCurve.sol";
import "../interfaces/IOracle.sol";

/// @title BondingCurveEvents
/// @author Angle Core Team
/// @notice All the events used in `BondingCurve` contract
contract BondingCurveEvents {
    event BondingCurveInit(uint256 _startPrice, address indexed _soldToken);

    event StartPriceUpdated(uint256 _startPrice);

    event TokensToSellUpdated(uint256 _tokensToSell);

    event TokenSale(uint256 _quantityOfANGLESold, address indexed _stableCoinUsed, uint256 _amountToPayInAgToken);

    event ModifiedStablecoin(address indexed _agToken, bool _isReference, address indexed _oracle);

    event RevokedStablecoin(address indexed _agToken);

    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);
}
