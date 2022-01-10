// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/IPoolManager.sol";
import "../interfaces/IStableMaster.sol";
import "../interfaces/ISanToken.sol";
import "./BaseSurplusConverter.sol";

interface IStableMasterFront {
    function deposit(
        uint256 amount,
        address to,
        address poolManager
    ) external;
}

/// @title SurplusConverterSanTokens
/// @author Angle Core Team
/// @notice A contract to swap tokens from the surplus of the protocol to a reward token
/// (could be ANGLE tokens, or another type of token)
/// @dev This contract gets sanTokens from a token of the Angle protocol
contract SurplusConverterSanTokens is BaseSurplusConverter {
    using SafeERC20 for IERC20;

    event PathUpdated(address indexed token, bytes newPath, bytes oldPath);
    event TokenRevoked(address indexed token);

    IStableMasterFront public immutable stableMaster;
    address public immutable poolManager;
    address public immutable supportedToken;

    /// @notice Constructor of the `SurplusConverterSanTokens`
    /// @param _rewardToken Reward token that this contract tries to buy
    /// @param _feeDistributor Reference to the contract handling fee distribution
    /// @param _stableMaster Reference to the `stableMaster` contract
    /// @param whitelisted Reference to the first whitelisted address that will have the right
    /// @param governor Governor of the protocol
    /// @param guardians List of guardians of the protocol
    constructor(
        address _rewardToken,
        address _feeDistributor,
        address _stableMaster,
        address whitelisted,
        address governor,
        address[] memory guardians
    ) BaseSurplusConverter(_rewardToken, _feeDistributor, whitelisted, governor, guardians) {
        require(_stableMaster != address(0), "0");
        stableMaster = IStableMasterFront(_stableMaster);
        // This will revert if the rewardToken of this contract is not a sanToken
        address poolManagerInt = ISanToken(_rewardToken).poolManager();
        poolManager = poolManagerInt;
        address supportedTokenInt = IPoolManager(poolManagerInt).token();
        supportedToken = supportedTokenInt;
        IERC20(supportedTokenInt).safeApprove(_stableMaster, type(uint256).max);
    }

    /// @notice Mints `rewardToken` from the protocol itself using the accumulated `token` and distributes
    /// the results of the swaps to the `FeeDistributor` or some other `SurplusConverter` contract
    /// @param token Token to use for buybacks of `rewardToken`
    /// @param amount Amount of tokens to use for the buyback
    /// @param transfer Whether the function should transfer the bought back `rewardToken` directly to the `FeeDistributor`
    /// contract or to the associated `SurplusConverter` contract
    /// @dev In this contract the `rewardToken` is a sanToken, so this function essentially deposits collateral
    /// in the Angle Protocol
    /// @dev There is no need to put slippage protection here as there is no slippage for SLPs deposits in the Angle
    /// Protocol
    function buyback(
        address token,
        uint256 amount,
        uint256,
        bool transfer
    ) external override whenNotPaused onlyRole(WHITELISTED_ROLE) {
        require(token == supportedToken, "20");
        stableMaster.deposit(amount, address(this), poolManager);
        if (transfer) {
            // This call will automatically transfer all the `rewardToken` balance of this contract to the `FeeDistributor`
            feeDistributor.burn(address(rewardToken));
        }
    }
}
