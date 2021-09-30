// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../external/AccessControlUpgradeable.sol";

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

    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event PerpetualUpdated(uint256 _perpetualID, uint256 _margin);

    event PerpetualOpened(uint256 _perpetualID, uint256 _entryRate, uint256 _margin, uint256 _committedAmount);

    // ============================== Parameters ===================================

    event BaseURIUpdated(string _baseURI);

    event LockTimeUpdated(uint64 _lockTime);

    event KeeperFeesCapUpdated(uint256 _keeperFeesLiquidationCap, uint256 _keeperFeesClosingCap);

    event TargetAndLimitHAHedgeUpdated(uint64 _targetHAHedge, uint64 _limitHAHedge);

    event BoundsPerpetualUpdated(uint64 _maxLeverage, uint64 _maintenanceMargin);

    event HAFeesUpdated(uint64[] _xHAFees, uint64[] _yHAFees, uint8 deposit);

    event KeeperFeesLiquidationRatioUpdated(uint64 _keeperFeesLiquidationRatio);

    event KeeperFeesClosingUpdated(uint64[] xKeeperFeesClosing, uint64[] yKeeperFeesClosing);

    // =============================== Reward ======================================

    event RewardAdded(uint256 _reward);

    event RewardPaid(address indexed _user, uint256 _reward);

    event RewardsDistributionUpdated(address indexed _rewardsDistributor);

    event RewardsDistributionDurationUpdated(uint256 _rewardsDuration, address indexed _rewardsDistributor);

    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);
}
