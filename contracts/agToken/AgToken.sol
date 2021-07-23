// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./AgTokenEvents.sol";

/// @title AgToken
/// @author Angle Core Team
/// @notice Base contract for agToken, that is to say Angle's stablecoins
/// @dev This contract is used to create and handle the stablecoins of Angle protocol
/// @dev Only the `StableMaster` contract can mint or burn agTokens
/// @dev It is still possible for any address to burn its agTokens without redeeming collateral in exchange
contract AgToken is AgTokenEvents, IAgTokenFunctions, AccessControlUpgradeable, ERC20PermitUpgradeable {
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role for `StableMaster` only
    bytes32 public constant STABLEMASTER_ROLE = keccak256("STABLEMASTER_ROLE");

    // ========================= References to other contracts =====================

    /// @notice Reference to the `StableMaster` contract associated to this `AgToken`
    address public stableMaster;

    /// @notice Maximum amount of stablecoin in circulation
    uint256 public capOnStablecoin;

    /// @notice Maximum amount that can be minted at once
    uint256 public maxMintAmount;

    // ============================= Constructor ===================================

    /// @notice Initializes the `AgToken` contract
    /// @param name_ Name of the token
    /// @param symbol_ Symbol of the token
    /// @param stableMaster_ Reference to the `StableMaster` contract associated to this agToken
    /// @param capOnStablecoin_ Max amount of stablecoin in circulation
    /// @dev This function is to be called by the `StableMaster` initializing a stablecoin
    function initialize(
        string memory name_,
        string memory symbol_,
        address stableMaster_,
        uint256 capOnStablecoin_,
        uint256 maxMintAmount_
    ) public initializer {
        __AccessControl_init();
        __ERC20Permit_init(name_);
        __ERC20_init(name_, symbol_);
        __Context_init();

        require(stableMaster_ != address(0), "zero address");

        // Creating a correct reference
        stableMaster = stableMaster_;
        capOnStablecoin = capOnStablecoin_;
        maxMintAmount = maxMintAmount_;
        // Access Control
        // All the roles in this contract are handled by the `StableMaster`
        // `StableMaster` also has the `GUARDIAN_ROLE`
        _setupRole(STABLEMASTER_ROLE, address(stableMaster));
        _setRoleAdmin(STABLEMASTER_ROLE, STABLEMASTER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, STABLEMASTER_ROLE);
    }

    /// @notice Initiates the guardian role
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Guardian address of the protocol
    /// @dev Guardian role only serves to set the new maximum amount of stablecoins currently minted and
    /// the max amount that can be minted at once
    /// @dev There is no specific governor role in this contract
    /// @dev `governorList` and `guardian` are parameters that are directly inherited from the `Core` contract
    function deploy(address[] memory governorList, address guardian) external override onlyRole(STABLEMASTER_ROLE) {
        grantRole(GUARDIAN_ROLE, guardian);
        for (uint256 i = 0; i < governorList.length; i++) {
            grantRole(GUARDIAN_ROLE, governorList[i]);
        }
    }

    // ========================= Governor Functions ================================

    /// @notice Sets a different cap on the amount of stablecoin that can be minted
    /// @param _capOnStablecoin New maximum amount of stablecoin in circulation
    /// @dev During the test phase this may be set to stress test the protocol in real market conditions,
    /// after this phase, the cap could be set to `type(uint256).max`, which is equivalent to having no cap
    function setCapOnStablecoin(uint256 _capOnStablecoin) external onlyRole(GUARDIAN_ROLE) {
        capOnStablecoin = _capOnStablecoin;
        emit CapOnStablecoinUpdated(_capOnStablecoin);
    }

    /// @notice Sets the maximum mint amount in one transaction
    /// @param _maxMintAmount New maximum amount of stablecoin minted in one time
    /// @dev Like for the `capOnStablecoin` parameter, this could be set to stress test the protocol in real market
    /// conditions. To get rid of this cap, we just have to set the parameter to `type(uint256).max`
    function setMaxMintAmount(uint256 _maxMintAmount) external onlyRole(GUARDIAN_ROLE) {
        maxMintAmount = _maxMintAmount;
        emit MaxMintAmountUpdated(_maxMintAmount);
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
    /// @dev This function is used in the `bondingCurve` where agTokens are burnt
    ///  and ANGLE tokens are given in exchange
    function burnFromNoRedeem(address account, uint256 amount) external override {
        _burnFromNoRedeem(amount, account, msg.sender);
    }

    // ========================= `StableMaster` Functions ==========================

    /// @notice Burns `amount` tokens from a `burner` address
    /// @param amount Amount of tokens to burn
    /// @param burner Address to burn from
    /// @dev This method is to be called by the `StableMaster` contract after being requested to do so
    /// by an address willing to burn tokens from its address
    function burnSelf(uint256 amount, address burner) external override onlyRole(STABLEMASTER_ROLE) {
        _burn(burner, amount);
    }

    /// @notice Burns `amount` tokens from a `burner` address after being asked to by `sender`
    /// @param amount Amount of tokens to burn
    /// @param burner Address to burn from
    /// @param sender Address which requested the burn from `burner`
    /// @dev This method is to be called by the `StableMaster` contract after being requested to do so
    /// by a `sender` address willing to burn tokens from another `sender` address
    /// @dev The method checks the allowance between the `sender` and the `burner`
    function burnFrom(
        uint256 amount,
        address burner,
        address sender
    ) external override onlyRole(STABLEMASTER_ROLE) {
        _burnFromNoRedeem(amount, burner, sender);
    }

    /// @notice Lets the `StableMaster` contract mint agTokens
    /// @param account Address to mint to
    /// @param amount Amount to mint
    /// @dev Only the `StableMaster` contract can issue agTokens
    function mint(address account, uint256 amount) external override onlyRole(STABLEMASTER_ROLE) {
        require(totalSupply() + amount <= capOnStablecoin && amount <= maxMintAmount, "mint violation");
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
