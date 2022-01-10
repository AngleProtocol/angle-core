// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/IFeeDistributor.sol";
import "../external/AccessControl.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title BaseSurplusConverter
/// @author Angle Core Team
/// @notice A base contract for the swap tokens from the surplus of the protocol to a reward token
/// (could be ANGLE tokens, or another type of token like sanTokens)
/// @dev All contracts implementing such swap features in Angle should implement this base contract
abstract contract BaseSurplusConverter is
  AccessControl,
  Pausable,
  IFeeDistributor
{
  using SafeERC20 for IERC20;

  event FeeDistributorUpdated(
    address indexed newFeeDistributor,
    address indexed oldFeeDistributor
  );
  event Recovered(
    address indexed tokenAddress,
    address indexed to,
    uint256 amount
  );

  /// @notice Role for governor of this contract
  bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

  /// @notice Role for guardians of this contract
  bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

  /// @notice Role for addresses allowed to redistribute the protocol's surplus
  bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");

  /// @notice Address responsible for distributing bought back reward tokens to veANGLE holders or for swapping
  /// the reward token of this contract to another token
  IFeeDistributor public feeDistributor;

  /// @notice Reward Token obtained by this contract
  IERC20 public immutable rewardToken;

  /// @notice Constructor of the `BaseSurplusConverter`
  /// @param _rewardToken Reward token that this contract tries to buy or otain
  /// @param _feeDistributor Reference to the contract handling fee distribution
  /// @param whitelisted Reference to the first whitelisted address that will have the right to perform buybacks
  /// @param governor Governor of the protocol
  /// @param guardians List of guardians of the protocol
  /// @dev Having a list of guardians as a parameter facilitates deployment of the contract
  constructor(
    address _rewardToken,
    address _feeDistributor,
    address whitelisted,
    address governor,
    address[] memory guardians
  ) {
    require(
      _feeDistributor != address(0) &&
        whitelisted != address(0) &&
        governor != address(0),
      "0"
    );
    feeDistributor = IFeeDistributor(_feeDistributor);
    rewardToken = IERC20(_rewardToken);
    // The function is going to revert because of the following call if the `_rewardToken` parameter is the
    // zero address
    IERC20(_rewardToken).safeApprove(_feeDistributor, type(uint256).max);
    require(guardians.length > 0, "101");
    for (uint256 i = 0; i < guardians.length; i++) {
      require(guardians[i] != address(0), "0");
      _setupRole(GUARDIAN_ROLE, guardians[i]);
    }
    _setupRole(WHITELISTED_ROLE, whitelisted);
    _setupRole(GOVERNOR_ROLE, governor);
    _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
    _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);
    _setRoleAdmin(WHITELISTED_ROLE, GOVERNOR_ROLE);
    // Contract is paused after deployment
    _pause();
  }

  /// @notice Changes the reference to the `FeeDistributor` allowed to distribute rewards to veANGLE holders
  /// or to swap the reward token to another token
  /// @param _feeDistributor Reference to the new `FeeDistributor`
  /// @dev This function is a governor only function as it could technically be used to withdraw funds from the protocol
  function setFeeDistributor(address _feeDistributor)
    external
    onlyRole(GOVERNOR_ROLE)
  {
    require(_feeDistributor != address(0), "0");
    address oldFeeDistributor = address(feeDistributor);
    feeDistributor = IFeeDistributor(_feeDistributor);
    IERC20 rewardTokenMem = rewardToken;
    rewardTokenMem.safeApprove(_feeDistributor, type(uint256).max);
    rewardTokenMem.safeApprove(oldFeeDistributor, 0);
    emit FeeDistributorUpdated(_feeDistributor, oldFeeDistributor);
  }

  /// @notice Withdraws ERC20 tokens that could accrue on this contract
  /// @param tokenAddress Address of the ERC20 token to withdraw
  /// @param to Address to transfer to
  /// @param amount Amount to transfer
  /// @dev Added to support recovering rewardToken in case of impossible buybacks
  /// and other tokens mistakenly sent to this contract
  function recoverERC20(
    address tokenAddress,
    address to,
    uint256 amount
  ) external onlyRole(GOVERNOR_ROLE) {
    IERC20(tokenAddress).safeTransfer(to, amount);
    emit Recovered(tokenAddress, to, amount);
  }

  /// @notice Pauses the `buyback`, `sendToFeeDistributor` and `burn` methods
  /// @dev After calling this function, it is going to be impossible for whitelisted addresses to buyback
  /// reward tokens or to send the bought back tokens to the `FeeDistributor`
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /// @notice Unpauses the `buyback` and `sendToFeeDistributor` methods
  function unpause() external onlyRole(GUARDIAN_ROLE) {
    _unpause();
  }

  /// @notice Buys back `rewardToken` using the accumulated `token` and distributes the results of the
  /// swaps to the `FeeDistributor` contract
  /// @param token Token to use for buybacks of `rewardToken`
  /// @param amount Amount of tokens to use for the buyback
  /// @param minAmount Specify the minimum amount to receive - slippage protection
  /// @param transfer Whether the function should transfer the bought back `rewardToken` directly to the `FeeDistributor`
  /// contract
  /// @dev This function should revert if `amount` is inferior to the amount of `token` owned by this contract
  /// @dev The reason for the variable `amount` instead of simply using the whole contract's balance for buybacks
  /// is that it gives more flexibility to the addresses handling buyback to optimize for the swap prices
  /// @dev This function should be whitelisted because arbitrageurs could take advantage of it to do sandwich attacks
  /// by just calling this function. Calls to this function could be sandwiched too but it's going harder for miners to
  /// setup sandwich attacks
  function buyback(
    address token,
    uint256 amount,
    uint256 minAmount,
    bool transfer
  ) external virtual;

  /// @notice Pulls tokens from another `SurplusConverter` contract
  /// @param token Address of the token to pull
  /// @dev This function is what allows for composability between different `SurplusConverter` contracts: a surplus converter
  /// having swapped tokens can send its output token to another surplus converter, responsible for doing another type
  /// of conversion, by calling this contract
  function burn(address token) external override whenNotPaused {
    IERC20(token).safeTransferFrom(
      msg.sender,
      address(this),
      IERC20(token).balanceOf(msg.sender)
    );
  }

  /// @notice This function transfers all the accumulated `rewardToken` to the `FeeDistributor` contract
  /// @dev This reason for having this function rather than doing such transfers directly in the `buyback` function is that
  /// it can allow to batch transfers and thus optimizes for gas
  function sendToFeeDistributor() external whenNotPaused {
    feeDistributor.burn(address(rewardToken));
  }
}
