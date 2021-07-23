// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IFeeManager.sol";
import "../interfaces/IPoolManager.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IPerpetualManager.sol";
import "../interfaces/IRewardsDistributor.sol";
import "../interfaces/IStableMaster.sol";
import "../interfaces/IStakingRewards.sol";

import "../utils/FunctionUtils.sol";

/// @title PerpetualManagerEvents
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains all the events of the `PerpetualManager` contract
contract PerpetualManagerEvents {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    event PerpetualUpdate(
        uint256 _perpetualID,
        uint256 _initRate,
        uint256 _cashOutAmount,
        uint256 _committedAmount,
        uint256 _fees
    );

    // ============================== Parameters ===================================

    event MaxALockUpdated(uint256 _maxALock);

    event SecureBlocksUpdated(uint256 _secureBlocks);

    event MaxLeverageUpdated(uint256 _maxLeverage);

    event CashOutLeverageUpdated(uint256 _cashOutLeverage);

    event MaintenanceMarginUpdated(uint256 _maintenanceMargin);

    event HAFeesDepositUpdated(uint256[] _xHAFeesDeposit, uint256[] _yHAFeesDeposit);

    event HAFeesWithdrawUpdated(uint256[] _xHAFeesWithdraw, uint256[] _yHAFeesWithdraw);

    event KeeperFeesRatioUpdated(uint256 _keeperFeesRatio);

    event KeeperFeesCapUpdated(uint256 _keeperFeesCap);

    event KeeperFeesCashOutUpdated(uint256[] xKeeperFeesCashOut, uint256[] yKeeperFeesCashOut);

    // =============================== Reward ======================================

    event RewardAdded(uint256 _reward);

    event RewardPaid(address indexed _user, uint256 _reward);

    event RewardsDistributorUpdated(address _rewardsDistributor);

    event RewardDistributionUpdated(uint256 _rewardsDuration, address _rewardsDistributor);
}
