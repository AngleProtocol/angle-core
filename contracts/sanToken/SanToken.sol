// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
// OpenZeppelin may update its version of the ERC20PermitUpgradeable token
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

import "../interfaces/IPoolManager.sol";
import "../interfaces/ISanToken.sol";
import "../interfaces/IStableMaster.sol";

/// @title SanToken
/// @author Angle Core Team
/// @notice Base contract for sanTokens, these tokens are used to mark the debt the contract has to SLPs
/// @dev The exchange rate between sanTokens and collateral will automatically change as interests and transaction fees accrue to SLPs
/// @dev There is one `SanToken` contract per pair stablecoin/collateral
contract SanToken is ISanToken, ERC20PermitUpgradeable {
    /// @notice Checks to see if it is the `StableMaster` calling this contract
    /// @dev There is no Access Control here, because it can be handled cheaply through these modifiers
    modifier onlyStableMaster() {
        require(msg.sender == stableMaster, "incorrect caller");
        _;
    }

    /// @notice Number of decimals used for this ERC20
    uint8 public decimal;

    // ========================= References to other contracts =====================

    /// @notice Address of the corresponding `StableMaster` contract
    /// This address cannot be modified
    address public stableMaster;

    // =============================== Constructor =================================

    /// @notice Initializes the `SanToken` contract
    /// @param name_ Name of the token
    /// @param symbol_ Symbol of the token
    /// @param poolManager Reference to the `PoolManager` contract associated to this `SanToken`
    function initialize(
        string memory name_,
        string memory symbol_,
        address poolManager
    ) public initializer {
        __ERC20Permit_init(name_);
        __ERC20_init(name_, symbol_);
        stableMaster = IPoolManager(poolManager).stableMaster();
        decimal = IERC20MetadataUpgradeable(IPoolManager(poolManager).token()).decimals();
    }

    // ========================= External Functions ================================

    /// @notice Returns the number of decimals used to get its user representation.
    /// @dev For example, if `decimals` equals `2`, a balance of `505` tokens should
    /// be displayed to a user as `5,05` (`505 / 10 ** 2`)
    /// @dev Tokens usually opt for a value of 18, imitating the relationship between
    /// Ether and Wei. This is the value {ERC20} uses, unless this function is overridden
    function decimals() public view override returns (uint8) {
        return decimal;
    }

    /// @notice Destroys `amount` token for the caller without giving collateral back
    /// @param amount Amount to burn
    function burnNoRedeem(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ===================== `StableMaster` Functions ==============================

    /// @notice Lets the `StableMaster` contract mint sanTokens
    /// @param account Address to mint to
    /// @param amount Amount to mint
    /// @dev Only the `StableMaster` contract can issue sanTokens
    /// @dev There is no need to make this function pausable (as well as the `StableMaster` functions below)
    /// as the corresponding function can directly be paused from the `StableMaster`
    function mint(address account, uint256 amount) external override onlyStableMaster {
        _mint(account, amount);
    }

    /// @notice Lets an address burn sanTokens and redeem collateral for this address
    /// @param amount Amount of sanTokens to burn from caller
    /// @dev This can only be called by the `StableMaster` which performs all the security checks
    /// to see for instance if the `burner` was the initial `msg.sender`
    function burnSelf(uint256 amount, address burner) external override onlyStableMaster {
        _burn(burner, amount);
    }

    /// @notice Lets an address burn sanTokens on behalf of another address and redeem
    /// collateral that will go to this other address
    /// @param burner Address to burn from and to redeem collateral to
    /// @param amount Amount of sanTokens to burn
    /// @dev Only the `StableMaster` can call this function
    function burnFrom(
        uint256 amount,
        address burner,
        address sender
    ) external override onlyStableMaster {
        uint256 currentAllowance = allowance(burner, sender);
        require(currentAllowance >= amount, "burn amount exceeds allowance");
        _approve(burner, sender, currentAllowance - amount);
        _burn(burner, amount);
    }
}
