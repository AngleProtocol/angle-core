// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/external/uniswap/IUniswapRouter.sol";
import "./BaseSurplusConverter.sol";

/// @title SurplusConverterUniV2Sushi
/// @author Angle Core Team
/// @notice A contract to swap tokens from the surplus of the protocol to a reward token
/// (could be ANGLE tokens, or another type of token)
/// @dev This contract for each swap compares swaps using UniswapV2 with swaps using Sushiswap and does the swap with the
/// exchange with the best price
contract SurplusConverterUniV2Sushi is BaseSurplusConverter {
    using SafeERC20 for IERC20;

    event PathAdded(address indexed token, address[] path, uint8 typePath);
    event PathRevoked(address indexed token, uint8 _type);

    // Struct to store for a given token the Uniswap Path
    struct Path {
        address[] pathAddresses;
        uint256 lengthAddresses;
    }

    /// @notice Address of the uniswapV2Router for swaps
    IUniswapV2Router public immutable uniswapV2Router;

    /// @notice Address of the sushiswapV2Router for swaps
    IUniswapV2Router public immutable sushiswapRouter;

    /// @notice Maps a token to the related path on Uniswap to do the swap to the reward token
    mapping(address => Path) public uniswapPaths;

    /// @notice Maps a token to the related path on Sushiswap to do the swap to the reward token
    mapping(address => Path) public sushiswapPaths;

    /// @notice Constructor of the `SurplusConverterUniV2Sushi`
    /// @param _rewardToken Reward token that this contract tries to buy
    /// @param _feeDistributor Reference to the contract handling fee distribution
    /// @param _uniswapV2Router Reference to the `UniswapV2Router`
    /// @param _sushiswapRouter Reference to the `SushiswapRouter`
    /// @param whitelisted Reference to the first whitelisted address that will have the right
    /// @param guardians List of guardians of the protocol
    constructor(
        address _rewardToken,
        address _feeDistributor,
        address _uniswapV2Router,
        address _sushiswapRouter,
        address whitelisted,
        address[] memory guardians
    ) BaseSurplusConverter(_rewardToken, _feeDistributor, whitelisted, guardians) {
        require(_uniswapV2Router != address(0) && _sushiswapRouter != address(0), "0");
        sushiswapRouter = IUniswapV2Router(_sushiswapRouter);
        uniswapV2Router = IUniswapV2Router(_uniswapV2Router);
    }

    /// @notice Adds a token to support with this contract
    /// @param token Token to add to this contract
    /// @param path Path used for the swap
    /// @param typePath Type of path specified, i.e is it a path for Sushiswap or for Uniswap
    /// @dev `typePath = 0` corresponds to a Sushiswap path
    /// @dev `typePath = 1` corresponds to a Uniswap path
    /// @dev This function can be called to change the path for a token or to add support
    /// for Uniswap or for Sushiswap
    function addToken(
        address token,
        address[] memory path,
        uint8 typePath
    ) external onlyRole(GUARDIAN_ROLE) {
        require(token != address(0), "0");
        uint256 pathLength = path.length;
        require(pathLength >= 2 && path[pathLength - 1] == address(rewardToken) && path[0] == token, "111");
        if (typePath == 0) {
            if (sushiswapPaths[token].lengthAddresses == 0) {
                // If this path is for a brand new token, then we need to approve the Sushiswap Router contract
                IERC20(token).safeApprove(address(sushiswapRouter), type(uint256).max);
            }
            sushiswapPaths[token].pathAddresses = path;
            sushiswapPaths[token].lengthAddresses = pathLength;
        } else {
            if (uniswapPaths[token].lengthAddresses == 0) {
                // If this path is a brand new path, then we need to approve the Uniswap Router contract
                IERC20(token).safeApprove(address(uniswapV2Router), type(uint256).max);
            }
            uniswapPaths[token].pathAddresses = path;
            uniswapPaths[token].lengthAddresses = pathLength;
        }
        emit PathAdded(token, path, typePath);
    }

    /// @notice Getter defined to easily get access to the array of addresses corresponding to a token
    /// @param token Token to query
    /// @param typePath Type of path to fetch (= 0 if Sushiswap, > 0 if Uniswap)
    function getPath(address token, uint8 typePath) external view returns (address[] memory) {
        if (typePath == 0) {
            return sushiswapPaths[token].pathAddresses;
        } else {
            return uniswapPaths[token].pathAddresses;
        }
    }

    /// @notice Revokes a supported token by this contract or just a path for this token
    /// @param token Token to revoke
    /// @param _type Type of revokation to make
    /// @dev `_type = 0` means that both Uniswap and Sushiswap paths should be revoked: the token is no longer handled
    /// @dev `type = 1` means that just the Sushiswap path needs to be revoked
    /// @dev Other cases mean that just the Uniswap path should be revoked
    function revokeToken(address token, uint8 _type) external onlyRole(GUARDIAN_ROLE) {
        if (_type == 0) {
            delete sushiswapPaths[token];
            delete uniswapPaths[token];
            IERC20(token).safeApprove(address(uniswapV2Router), 0);
            IERC20(token).safeApprove(address(sushiswapRouter), 0);
        } else if (_type == 1) {
            delete sushiswapPaths[token];
            IERC20(token).safeApprove(address(sushiswapRouter), 0);
        } else {
            delete uniswapPaths[token];
            IERC20(token).safeApprove(address(uniswapV2Router), 0);
        }
        emit PathRevoked(token, _type);
    }

    /// @notice Buys back `rewardToken` from Uniswap or Sushiswap using the accumulated `token` and distributes
    /// the results of the swaps to the `FeeDistributor` contract
    /// @param token Token to use for buybacks of `rewardToken`
    /// @param amount Amount of tokens to use for the buyback
    /// @param transfer Whether the function should transfer the bought back `rewardToken` directly to the `FeeDistributor`
    /// contract
    /// @dev If a `token` has two paths associated to it (one from Uniswap, one from Sushiswap), this function optimizes
    /// and chooses the best path
    function buyback(
        address token,
        uint256 amount,
        bool transfer
    ) external override whenNotPaused onlyRole(WHITELISTED_ROLE) {
        uint256 sushiswapLength = sushiswapPaths[token].lengthAddresses;
        uint256 uniswapLength = uniswapPaths[token].lengthAddresses;
        require(sushiswapLength > 0 || uniswapLength > 0, "20");
        // uint256 amount = IERC20(token).balanceOf(address(this));
        if (sushiswapLength > 0 && uniswapLength > 0) {
            uint256[] memory amountsUni = uniswapV2Router.getAmountsOut(amount, uniswapPaths[token].pathAddresses);
            uint256[] memory amountsSushi = sushiswapRouter.getAmountsOut(amount, sushiswapPaths[token].pathAddresses);
            if (amountsUni[amountsUni.length - 1] >= amountsSushi[amountsSushi.length - 1]) {
                uniswapV2Router.swapExactTokensForTokens(
                    amount,
                    0,
                    uniswapPaths[token].pathAddresses,
                    address(this),
                    block.timestamp
                );
            } else {
                sushiswapRouter.swapExactTokensForTokens(
                    amount,
                    0,
                    sushiswapPaths[token].pathAddresses,
                    address(this),
                    block.timestamp
                );
            }
        } else if (sushiswapLength > 0) {
            sushiswapRouter.swapExactTokensForTokens(
                amount,
                0,
                sushiswapPaths[token].pathAddresses,
                address(this),
                block.timestamp
            );
        } else {
            uniswapV2Router.swapExactTokensForTokens(
                amount,
                0,
                uniswapPaths[token].pathAddresses,
                address(this),
                block.timestamp
            );
        }
        if (transfer) {
            // This call will automatically transfer all the `rewardToken` balance of this contract to the `FeeDistributor`
            feeDistributor.burn(address(rewardToken));
        }
    }
}
