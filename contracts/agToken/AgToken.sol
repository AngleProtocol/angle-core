// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "../interfaces/IAgToken.sol";
// OpenZeppelin may update its version of the ERC20PermitUpgradeable token
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

/// @title AgToken
/// @author Angle Core Team
/// @notice Base contract for agToken, that is to say Angle's stablecoins
/// @dev This contract is used to create and handle the stablecoins of Angle protocol
/// @dev Only the `StableMaster` contract can mint or burn agTokens
/// @dev It is still possible for any address to burn its agTokens without redeeming collateral in exchange
contract AgToken is IAgToken, ERC20PermitUpgradeable {
    // ========================= References to other contracts =====================

    /// @notice Reference to the `StableMaster` contract associated to this `AgToken`
    address public override stableMaster;

    // ============================= Constructor ===================================

    /// @notice Initializes the `AgToken` contract
    /// @param name_ Name of the token
    /// @param symbol_ Symbol of the token
    /// @param stableMaster_ Reference to the `StableMaster` contract associated to this agToken
    /// @dev By default, `agToken` are ERC-20 tokens with 18 decimals
    function initialize(
        string memory name_,
        string memory symbol_,
        address stableMaster_
    ) public initializer {
        __ERC20Permit_init(name_);
        __ERC20_init(name_, symbol_);
        require(stableMaster_ != address(0), "zero address");
        stableMaster = stableMaster_;
    }

    /// @notice Checks to see if it is the `StableMaster` calling this contract
    /// @dev There is no Access Control here, because it can be handled cheaply through this modifier
    modifier onlyStableMaster() {
        require(msg.sender == stableMaster, "incorrect caller");
        _;
    }

    // ========================= External Functions ================================

    /// @notice Destroys `amount` token from the caller without giving collateral back
    /// @param amount Amount to burn
    function burnNoRedeem(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burns `amount` of agToken on behalf of another account without redeeming collateral back
    /// @param account Account to burn on behalf of
    /// @param amount Amount to burn
    /// @dev This function is used in the `BondingCurve` where agTokens are burnt
    /// and ANGLE tokens are given in exchange
    function burnFromNoRedeem(address account, uint256 amount) external override {
        _burnFromNoRedeem(amount, account, msg.sender);
    }

    // ========================= `StableMaster` Functions ==========================

    /// @notice Burns `amount` tokens from a `burner` address
    /// @param amount Amount of tokens to burn
    /// @param burner Address to burn from
    /// @dev This method is to be called by the `StableMaster` contract after being requested to do so
    /// by an address willing to burn tokens from its address
    function burnSelf(uint256 amount, address burner) external override onlyStableMaster {
        _burn(burner, amount);
    }

    /// @notice Burns `amount` tokens from a `burner` address after being asked to by `sender`
    /// @param amount Amount of tokens to burn
    /// @param burner Address to burn from
    /// @param sender Address which requested the burn from `burner`
    /// @dev This method is to be called by the `StableMaster` contract after being requested to do so
    /// by a `sender` address willing to burn tokens from another `burner` address
    /// @dev The method checks the allowance between the `sender` and the `burner`
    function burnFrom(
        uint256 amount,
        address burner,
        address sender
    ) external override onlyStableMaster {
        _burnFromNoRedeem(amount, burner, sender);
    }

    /// @notice Lets the `StableMaster` contract mint agTokens
    /// @param account Address to mint to
    /// @param amount Amount to mint
    /// @dev Only the `StableMaster` contract can issue agTokens
    function mint(address account, uint256 amount) external override onlyStableMaster {
        _mint(account, amount);
    }

    // ============================ Internal Function ==============================

    /// @notice Internal version of the function `burnFromNoRedeem`
    /// @param amount Amount to burn
    /// @dev It is at the level of this function that allowance checks are performed
    function _burnFromNoRedeem(
        uint256 amount,
        address burner,
        address sender
    ) internal {
        uint256 currentAllowance = allowance(burner, sender);
        require(currentAllowance >= amount, "burn amount exceeds allowance");
        _approve(burner, sender, currentAllowance - amount);
        _burn(burner, amount);
    }
}
