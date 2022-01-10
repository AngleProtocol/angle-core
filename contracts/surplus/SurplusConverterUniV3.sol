// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/external/uniswap/IUniswapRouter.sol";
import "./BaseSurplusConverter.sol";

/// @title SurplusConverterUniV3
/// @author Angle Core Team
/// @notice A contract to swap tokens from the surplus of the protocol to a reward token
/// (could be ANGLE tokens, or another type of token)
/// @dev This contract swaps tokens on UniV3
contract SurplusConverterUniV3 is BaseSurplusConverter {
    using SafeERC20 for IERC20;

    event PathUpdated(address indexed token, bytes newPath, bytes oldPath);
    event TokenRevoked(address indexed token);

    /// @notice Address of the uniswapV2Router for swaps
    IUniswapV3Router public immutable uniswapV3Router;

    /// @notice Maps a token to the related path on Uniswap to do the swap to the reward token
    mapping(address => bytes) public uniswapPaths;

    /// @notice Constructor of the `SurplusConverterUniV3`
    /// @param _rewardToken Reward token that this contract tries to buy
    /// @param _feeDistributor Reference to the contract handling fee distribution
    /// @param _uniswapV3Router Reference to the `UniswapV2Router`
    /// @param whitelisted Reference to the first whitelisted address that will have the right
    /// @param governor Governor of the protocol
    /// @param guardians List of guardians of the protocol
    constructor(
        address _rewardToken,
        address _feeDistributor,
        address _uniswapV3Router,
        address whitelisted,
        address governor,
        address[] memory guardians
    ) BaseSurplusConverter(_rewardToken, _feeDistributor, whitelisted, governor, guardians) {
        require(_uniswapV3Router != address(0), "0");
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
    }

    /// @notice Adds a token to support with this contract
    /// @param token Token to add to this contract
    /// @param pathAddresses Addresses used (in order) for the swap
    /// @param pathFees Fees used (in order) to get the path for the pool to use for the swap
    /// @dev This function can be called to change the path for a token or to add a new supported
    /// token
    function addToken(
        address token,
        address[] memory pathAddresses,
        uint24[] memory pathFees
    ) external onlyRole(GUARDIAN_ROLE) {
        require(token != address(0), "0");
        require(pathAddresses.length >= 2, "5");
        require(pathAddresses.length == (pathFees.length + 1), "104");
        require(pathAddresses[0] == token && pathAddresses[pathAddresses.length - 1] == address(rewardToken), "111");

        bytes memory path;
        for (uint256 i = 0; i < pathFees.length; i++) {
            require(pathAddresses[i] != address(0) && pathAddresses[i + 1] != address(0), "0");
            path = abi.encodePacked(path, pathAddresses[i], pathFees[i]);
        }
        path = abi.encodePacked(path, pathAddresses[pathFees.length]);

        // As this function can be sued to change the path for an existing token,
        // we're checking if a path already exists for this token before giving it
        // approval
        bytes memory oldPath = uniswapPaths[token];
        if (oldPath.length == 0) {
            IERC20(token).safeApprove(address(uniswapV3Router), type(uint256).max);
        }
        uniswapPaths[token] = path;
        emit PathUpdated(token, path, oldPath);
    }

    /// @notice Revokes a token supported by this contract
    /// @param token Token to add to this contract
    function revokeToken(address token) external onlyRole(GUARDIAN_ROLE) {
        delete uniswapPaths[token];
        IERC20(token).safeApprove(address(uniswapV3Router), 0);
        emit TokenRevoked(token);
    }

    /// @notice Buys back `rewardToken` from UniswapV3 using the accumulated `token` and distributes
    /// the results of the swaps to the `FeeDistributor` or some other `SurplusConverter` contract
    /// @param token Token to use for buybacks of `rewardToken`
    /// @param amount Amount of tokens to use for the buyback
    /// @param minAmount Specify the minimum amount to receive out of the swap as a slippage protection
    /// @param transfer Whether the function should transfer the bought back `rewardToken` directly to the `FeeDistributor`
    /// contract or to the associated `SurplusConverter`
    /// @dev This function always chooses the same path
    function buyback(
        address token,
        uint256 amount,
        uint256 minAmount,
        bool transfer
    ) external override whenNotPaused onlyRole(WHITELISTED_ROLE) {
        bytes memory path = uniswapPaths[token];
        require(path.length != 0, "111");
        uniswapV3Router.exactInput(ExactInputParams(path, address(this), block.timestamp, amount, minAmount));
        if (transfer) {
            // This call will automatically transfer all the `rewardToken` balance of this contract to the `FeeDistributor`
            feeDistributor.burn(address(rewardToken));
        }
    }
}
