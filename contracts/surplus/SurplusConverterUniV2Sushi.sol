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

  /// @notice Address of the uniswapV2Router for swaps
  IUniswapV2Router public immutable uniswapV2Router;

  /// @notice Address of the sushiswapV2Router for swaps
  IUniswapV2Router public immutable sushiswapRouter;

  /// @notice Maps a token to the related path on Uniswap to do the swap to the reward token
  mapping(address => address[]) public uniswapPaths;

  /// @notice Maps a token to the related path on Sushiswap to do the swap to the reward token
  mapping(address => address[]) public sushiswapPaths;

  /// @notice Constructor of the `SurplusConverterUniV2Sushi`
  /// @param _rewardToken Reward token that this contract tries to buy
  /// @param _feeDistributor Reference to the contract handling fee distribution
  /// @param _uniswapV2Router Reference to the `UniswapV2Router`
  /// @param _sushiswapRouter Reference to the `SushiswapRouter`
  /// @param whitelisted Reference to the first whitelisted address that will have the right
  /// @param governor Governor of the protocol
  /// @param guardians List of guardians of the protocol
  constructor(
    address _rewardToken,
    address _feeDistributor,
    address _uniswapV2Router,
    address _sushiswapRouter,
    address whitelisted,
    address governor,
    address[] memory guardians
  )
    BaseSurplusConverter(
      _rewardToken,
      _feeDistributor,
      whitelisted,
      governor,
      guardians
    )
  {
    require(
      _uniswapV2Router != address(0) && _sushiswapRouter != address(0),
      "0"
    );
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
    require(
      pathLength >= 2 &&
        path[pathLength - 1] == address(rewardToken) &&
        path[0] == token,
      "111"
    );
    if (typePath == 0) {
      if (sushiswapPaths[token].length == 0) {
        // If this path is for a brand new token, then we need to approve the Sushiswap Router contract
        IERC20(token).safeApprove(address(sushiswapRouter), type(uint256).max);
      }
      sushiswapPaths[token] = path;
    } else {
      if (uniswapPaths[token].length == 0) {
        // If this path is a brand new path, then we need to approve the Uniswap Router contract
        IERC20(token).safeApprove(address(uniswapV2Router), type(uint256).max);
      }
      uniswapPaths[token] = path;
    }
    emit PathAdded(token, path, typePath);
  }

  /// @notice Getter defined to easily get access to the array of addresses corresponding to a token
  /// @param token Token to query
  /// @param typePath Type of path to fetch (= 0 if Sushiswap, > 0 if Uniswap)
  function getPath(address token, uint8 typePath)
    external
    view
    returns (address[] memory)
  {
    if (typePath == 0) {
      return sushiswapPaths[token];
    } else {
      return uniswapPaths[token];
    }
  }

  /// @notice Revokes a supported token by this contract or just a path for this token
  /// @param token Token to revoke
  /// @param _type Type of revokation to make
  /// @dev `type = 0` means that just the Sushiswap path needs to be revoked
  /// @dev `type = 1` means that just the Uniswap path should be revoked
  /// @dev Other types mean that both Uniswap and Sushiswap paths should be revoked: the token is no longer handled
  function revokeToken(address token, uint8 _type)
    external
    onlyRole(GUARDIAN_ROLE)
  {
    if (_type == 0) {
      delete sushiswapPaths[token];
      IERC20(token).safeApprove(address(sushiswapRouter), 0);
    } else if (_type == 1) {
      delete uniswapPaths[token];
      IERC20(token).safeApprove(address(uniswapV2Router), 0);
    } else {
      delete sushiswapPaths[token];
      delete uniswapPaths[token];
      IERC20(token).safeApprove(address(uniswapV2Router), 0);
      IERC20(token).safeApprove(address(sushiswapRouter), 0);
    }
    emit PathRevoked(token, _type);
  }

  /// @notice Buys back `rewardToken` from Uniswap or Sushiswap using the accumulated `token` and distributes
  /// the results of the swaps to the `FeeDistributor` or some other `SurplusConverter` contract
  /// @param token Token to use for buybacks of `rewardToken`
  /// @param amount Amount of tokens to use for the buyback
  /// @param minAmount Specify the minimum amount to receive out of the swap as a slippage protection
  /// @param transfer Whether the function should transfer the bought back `rewardToken` directly to the `FeeDistributor`
  /// contract or to the associated other `SurplusConverter`
  /// @dev If a `token` has two paths associated to it (one from Uniswap, one from Sushiswap), this function optimizes
  /// and chooses the best path
  function buyback(
    address token,
    uint256 amount,
    uint256 minAmount,
    bool transfer
  ) external override whenNotPaused onlyRole(WHITELISTED_ROLE) {
    // Storing the values in memory to avoid multiple storage reads
    address[] memory sushiswapPath = sushiswapPaths[token];
    address[] memory uniswapPath = uniswapPaths[token];
    require(sushiswapPath.length > 0 || uniswapPath.length > 0, "20");
    if (sushiswapPath.length > 0 && uniswapPath.length > 0) {
      // Storing the router addresses in memory to avoid duplicate storage reads for one of the two
      // addresses
      IUniswapV2Router uniswapV2RouterMem = uniswapV2Router;
      IUniswapV2Router sushiswapRouterMem = sushiswapRouter;
      uint256[] memory amountsUni = uniswapV2RouterMem.getAmountsOut(
        amount,
        uniswapPath
      );
      uint256[] memory amountsSushi = sushiswapRouterMem.getAmountsOut(
        amount,
        sushiswapPath
      );
      if (
        amountsUni[amountsUni.length - 1] >=
        amountsSushi[amountsSushi.length - 1]
      ) {
        uniswapV2RouterMem.swapExactTokensForTokens(
          amount,
          minAmount,
          uniswapPath,
          address(this),
          block.timestamp
        );
      } else {
        sushiswapRouterMem.swapExactTokensForTokens(
          amount,
          minAmount,
          sushiswapPath,
          address(this),
          block.timestamp
        );
      }
    } else if (sushiswapPath.length > 0) {
      sushiswapRouter.swapExactTokensForTokens(
        amount,
        minAmount,
        sushiswapPath,
        address(this),
        block.timestamp
      );
    } else {
      uniswapV2Router.swapExactTokensForTokens(
        amount,
        minAmount,
        uniswapPath,
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
