// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
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

    event PerpetualCreated(uint256 _perpetualID, uint256 _entryRate, uint256 _margin, uint256 _committedAmount);

    // ============================== Parameters ===================================

    event LockTimeUpdated(uint256 _lockTime);

    event KeeperFeesCapUpdated(uint256 _keeperFeesLiquidationCap, uint256 _keeperFeesCashOutCap);

    event TargetAndLimitHACoverageUpdated(uint64 _targetHACoverage, uint64 _limitHACoverage);

    event BoundsPerpetualUpdated(uint64 _maxLeverage, uint64 _maintenanceMargin);

    event HAFeesUpdated(uint64[] _xHAFeesDeposit, uint64[] _yHAFeesDeposit, uint8 deposit);

    event KeeperFeesRatioUpdated(uint64 _keeperFeesRatio);

    event KeeperFeesCashOutUpdated(uint64[] xKeeperFeesCashOut, uint64[] yKeeperFeesCashOut);

    // =============================== Reward ======================================

    event RewardAdded(uint256 _reward);

    event RewardPaid(address indexed _user, uint256 _reward);

    event RewardsDistributorUpdated(address indexed _rewardsDistributor);

    event RewardDistributionUpdated(uint256 _rewardsDuration, address indexed _rewardsDistributor);

    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);
}
