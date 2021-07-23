// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./CollateralSettlerERC20Events.sol";

/// @title CollateralSettlerERC20
/// @author Angle Core Team
/// @notice A contract to settle the positions associated to a collateral for a given stablecoin
/// @dev In this contract the term LP refers to both SLPs and HAs
contract CollateralSettlerERC20 is CollateralSettlerERC20Events, ICollateralSettler, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for `StableMaster` only
    bytes32 public constant STABLEMASTER_ROLE = keccak256("STABLEMASTER_ROLE");
    /// @notice Base we use to compute ratios
    uint256 public constant BASE = 10**18;

    // Struct representing a claim that was made by sending governance tokens
    struct GovTokenClaim {
        // Number of gov tokens that is owed to users which claimed
        uint256 govTokens;
        // Value of the claim: this is the amount that is going to get treated preferably
        uint256 claim;
    }

    // =================== References to contracts =================================

    /// @notice Address of the `PerpetualManager` corresponding to the pool being closed
    IPerpetualManagerFront public perpetualManager;

    /// @notice Address of the `SanToken` corresponding to the pool being closed
    ISanToken public sanToken;

    /// @notice Address of the `AgToken` contract corresponding to the pool being closed
    IAgToken public agToken;

    /// @notice Address of the `PoolManager` corresponding to the pool being closed
    IPoolManager public poolManager;

    /// @notice Address of the ERC20 token corresponding to the collateral
    IERC20 public underlyingToken;

    /// @notice Governance token of the protocol
    /// It is stored here because users, HAs and SLPs can send governance tokens to get treated preferably
    /// in case of collateral settlement
    IERC20 public angle;

    // ============================ Parameters =====================================

    /// @notice Used to compute the portion of the user claim that is going to be considered as a claim
    /// with governance tokens for a unit amount of governance tokens brought
    uint256 public proportionalRatioGovUser = 0;

    /// @notice Used to compute the portion of the HA or SLP claim that is going to be considered as a claim
    /// with governance tokens for a unit amount of governance tokens brought
    uint256 public proportionalRatioGovLP = 0;

    /// @notice Time after the trigger in which users and LPs can come and claim their collateral
    uint256 public claimTime;

    // ========================= Activation Variables ==============================

    /// @notice Value of the oracle at settlement trigger time
    uint256 public oracleValue;

    /// @notice Exchange rate between sanTokens and collateral at settlement trigger time
    uint256 public sanRate;

    /// @notice Total amount of collateral to redistribute
    uint256 public amountToRedistribute = 0;

    /// @notice Time at which settlement was triggered, initialized at zero
    uint256 public startTimestamp = 0;

    // ======================= Accounting Variables ================================

    /// @notice Sum of the claims of users which did not bring governance tokens (expressed in collateral)
    uint256 public totalUserClaims = 0;

    /// @notice Sum of the claims of users which brought governance tokens (expressed in collateral)
    uint256 public totalUserClaimsWithGov = 0;

    /// @notice Sum of the claims from LPs
    uint256 public totalLpClaims = 0;

    /// @notice Sum of the claims from LPs which had governance tokens
    uint256 public totalLpClaimsWithGov = 0;

    /// @notice Ratio between what can be given and the claim for each user with gov tokens
    /// It is going to be updated (like the quantities below) only once at the end of the claim period
    uint256 public baseAmountToUserGov = 0;

    /// @notice Ratio between what can be given and the claim for each user
    uint256 public baseAmountToUser = 0;

    /// @notice Ratio between what can be given and the claim for each LP with gov tokens
    uint256 public baseAmountToLpGov = 0;

    /// @notice Ratio between what can be given and the claim for each LP
    uint256 public baseAmountToLp = 0;

    /// @notice Number used a boolean to see if the `setAmountToRedistributeEach` function
    /// has already been called
    /// @dev This function can only be called once throughout the lifetime of the contract
    uint256 public baseAmountToEachComputed = 0;

    // ============================= Mappings ======================================

    /// @notice Mapping between an address and a claim (in collateral) for a stable holder
    mapping(address => uint256) public userClaims;

    /// @notice Mapping between a user address, its claim and number of gov tokens due
    mapping(address => GovTokenClaim) public userClaimsWithGov;

    /// @notice Mapping between the address of a LP and a claim
    mapping(address => uint256) public lpClaims;

    /// @notice Mapping between the address of a LP, its claim and the number of gov tokens brouhgt
    mapping(address => GovTokenClaim) public lpClaimsWithGov;

    /// @notice Mapping to check whether a HA perpetual has already been redeemed
    mapping(uint256 => uint256) public haClaimCheck;

    // ================================= Modifiers =================================

    /// @notice Checks to see if the contract is currently in claim period
    modifier onlyClaimPeriod() {
        require(
            startTimestamp != 0 && block.timestamp < claimTime + startTimestamp && block.timestamp > startTimestamp,
            "invalid claim time"
        );
        _;
    }

    /// @notice Checks to see if the base amounts to distribute to each category have already been computed
    /// @dev This allows to verify if users and LPs can redeem their collateral
    /// @dev As the `baseAmountToEachComputed` can only be changed from 0 during redeem period, this modifier
    /// allows at the same time to check if claim period is over
    modifier onlyBaseAmountsComputed() {
        require(baseAmountToEachComputed != 0, "base amounts not computed");
        _;
    }

    // =============================== Constructor =================================

    /// @notice Collateral settler constructor
    /// @param _poolManager Address of the corresponding `PoolManager`
    /// @param _angle Address of the ANGLE token
    /// @param _claimTime Duration in which users and LPs will be able to claim their collateral
    /// @param governorList List of the governor addresses of the protocol
    /// @param stableMaster Address of the `StableMaster` contract allowed to trigger settlement
    /// @dev `stableMaster` here is useless as it can be retrieved from `_poolManager` but is used for testing purposes
    constructor(
        IPoolManager _poolManager,
        IERC20 _angle,
        uint256 _claimTime,
        address[] memory governorList,
        address stableMaster
    ) {
        require(address(_angle) != address(0) && address(stableMaster) != address(0), "zero address");
        // Retrieving from the `_poolManager` all the correct references, this guarantees the integrity of the contract
        poolManager = _poolManager;
        perpetualManager = IPerpetualManagerFront(_poolManager.perpetualManager());
        (, ISanToken _sanToken, , , , , , ) = IStableMaster(_poolManager.stableMaster()).collateralMap(_poolManager);
        sanToken = _sanToken;
        agToken = IAgToken(IStableMaster(_poolManager.stableMaster()).agToken());
        poolManager = _poolManager;
        underlyingToken = IERC20(_poolManager.token());
        angle = _angle;
        claimTime = _claimTime;

        // Access control
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "zero address");
            _setupRole(GOVERNOR_ROLE, governorList[i]);
        }
        _setupRole(STABLEMASTER_ROLE, stableMaster);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(STABLEMASTER_ROLE, GOVERNOR_ROLE);

        emit CollateralSettlerInit(address(poolManager), address(angle), claimTime);
    }

    // ========================== Contract Activation ==============================

    /// @notice Activates settlement for this contract, launches claim period and freezes oracle values
    /// @param _oracleValue Value of the oracle that will be used for the settlement to get the
    /// price of the concerned collateral with respect to that of the stablecoin
    /// @param _sanRate Value of the `sanRate` at time of settlement to be able to convert an amount of
    /// sanTokens to an amount of collateral
    /// @dev This function is to be called by the `StableMaster` after governance called `revokeCollateral`
    function triggerSettlement(uint256 _oracleValue, uint256 _sanRate) external override onlyRole(STABLEMASTER_ROLE) {
        oracleValue = _oracleValue;
        sanRate = _sanRate;
        startTimestamp = block.timestamp;
        amountToRedistribute = underlyingToken.balanceOf(address(this));
        emit SettlementTriggered(amountToRedistribute);
    }

    // =============================== User Claims =================================

    /// @notice Allows a user to claim collateral for a `dest` address by sending agTokens and gov tokens (optional)
    /// @param dest Address of the user to claim collateral for
    /// @param amountAgToken Amount of agTokens sent
    /// @param amountGovToken Amount of governance sent
    /// @dev The more gov tokens a user sent, the more preferably it ends up being treated during the redeem period
    function claimUser(
        address dest,
        uint256 amountAgToken,
        uint256 amountGovToken
    ) external onlyClaimPeriod whenNotPaused {
        require(dest != address(0), "zero address");
        // Since this involves a `transferFrom`, it is normal to update the variables after the transfers are done
        // No need to use `safeTransfer` for agTokens and ANGLE tokens
        agToken.transferFrom(msg.sender, address(this), amountAgToken);
        // Computing the amount of the claim from the number of stablecoins sent
        uint256 amountInC = (amountAgToken * BASE) / oracleValue;
        // Updating the contract's mappings accordingly
        _treatClaim(dest, amountGovToken, amountInC, 0);
    }

    // =============================== HA Claims ===================================

    /// @notice Allows a HA to claim collateral by sending a `perpetualID` and gov tokens (optional)
    /// @param perpetualID Perpetual owned by the HA
    /// @param amountGovToken Amount of governance sent
    /// @dev The contract automatically recognizes the beneficiary of the perpetual
    function claimHA(uint256 perpetualID, uint256 amountGovToken) external onlyClaimPeriod whenNotPaused {
        // Getting the owner of the perpetual
        // The zero address cannot own a perpetual
        address dest = perpetualManager.ownerOf(perpetualID);
        require(haClaimCheck[perpetualID] == 0, "perpetual already claimed");
        // A HA cannot claim a given perpetual twice
        haClaimCheck[perpetualID] = 1;
        // Computing the amount of the claim from the perpetual
        (uint256 amountInC, ) = perpetualManager.getCashOutAmount(perpetualID, oracleValue);
        // Updating the contract's mappings accordingly
        _treatClaim(dest, amountGovToken, amountInC, 1);
    }

    // =============================== SLP Claims ==================================

    /// @notice Allows a SLP to claim collateral for an address `dest` by sending sanTokens and gov tokens (optional)
    /// @param dest Address to claim collateral for
    /// @param amountSanToken Amount of sanTokens sent
    /// @param amountGovToken Amount of governance tokens sent
    function claimSLP(
        address dest,
        uint256 amountSanToken,
        uint256 amountGovToken
    ) external onlyClaimPeriod whenNotPaused {
        require(dest != address(0), "zero address");
        sanToken.transferFrom(msg.sender, address(this), amountSanToken);
        // Computing the amount of the claim from the number of sanTokens sent
        uint256 amountInC = (amountSanToken * sanRate) / BASE;
        // Updating the contract's mappings accordingly
        _treatClaim(dest, amountGovToken, amountInC, 1);
    }

    // ========================= Redeem Period =====================================

    /// @notice Computes the base amount each category of claim will get after the claim period has ended
    /// @dev This function can only be called once when claim period is over
    /// @dev It is at the level of this function that the waterfall between the different
    /// categories of stakeholders and of claims is executed
    function setAmountToRedistributeEach() external whenNotPaused {
        // Checking if it is the right time to call the function: claim period should be over
        require(startTimestamp != 0 && block.timestamp > claimTime + startTimestamp, "invalid redeem time");
        // This is what guarantees that this function can only be computed once
        require(baseAmountToEachComputed == 0, "base amounts already computed");
        baseAmountToEachComputed = 1;
        // The waterfall first gives everything that's possible to stable holders which had governance tokens
        // in the limit of what is owed to them
        if (amountToRedistribute >= totalUserClaimsWithGov) {
            baseAmountToUserGov = BASE;
            amountToRedistribute -= totalUserClaimsWithGov;
        } else {
            baseAmountToUserGov = (amountToRedistribute * BASE) / totalUserClaimsWithGov;
            amountToRedistribute = 0;
        }
        // Then it gives everything that remains to other stable holders (in the limit of what is owed to them)
        if (amountToRedistribute > totalUserClaims) {
            baseAmountToUser = BASE;
            amountToRedistribute -= totalUserClaims;
        } else {
            baseAmountToUser = (amountToRedistribute * BASE) / totalUserClaims;
            amountToRedistribute = 0;
        }
        // After that, LPs which had governance tokens claims are going to be treated: once again the contract
        // gives them everything it can in the limit of their claim
        if (amountToRedistribute > totalLpClaimsWithGov) {
            baseAmountToLpGov = BASE;
            amountToRedistribute -= totalLpClaimsWithGov;
        } else {
            baseAmountToLpGov = (amountToRedistribute * BASE) / totalLpClaimsWithGov;
            amountToRedistribute = 0;
        }
        // And last, LPs claims without governance tokens are handled
        if (amountToRedistribute > totalLpClaims) {
            baseAmountToLp = BASE;
            amountToRedistribute -= totalLpClaims;
        } else {
            baseAmountToLp = (amountToRedistribute * BASE) / totalLpClaims;
            amountToRedistribute = 0;
        }

        emit AmountToRedistributeAnnouncement(
            baseAmountToUserGov,
            baseAmountToUser,
            baseAmountToLpGov,
            baseAmountToLp,
            amountToRedistribute
        );
    }

    /// @notice Lets a user or a LP redeem its corresponding share of collateral
    /// @param user Address of the user to redeem collateral to
    /// @dev This function can only be called after the `setAmountToRedistributeEach` function has been called
    /// @dev The entry point to redeem is the same for users, HAs and SLPs
    function redeemCollateral(address user) external onlyBaseAmountsComputed whenNotPaused {
        uint256 amountToGive = (userClaimsWithGov[user].claim *
            baseAmountToUserGov +
            userClaims[user] *
            baseAmountToUser +
            lpClaimsWithGov[user].claim *
            baseAmountToLpGov +
            lpClaims[user] *
            baseAmountToLp) / BASE;
        uint256 amountGovTokens = lpClaimsWithGov[user].govTokens + userClaimsWithGov[user].govTokens;
        // Deleting the amounts stored for each so that someone cannot come and claim twice
        delete userClaimsWithGov[user];
        delete userClaims[user];
        delete lpClaimsWithGov[user];
        delete lpClaims[user];
        if (amountToGive > 0) {
            underlyingToken.safeTransfer(user, amountToGive);
        }
        if (amountGovTokens > 0) {
            angle.transfer(user, amountGovTokens);
        }
    }

    // ============================== Governance ===================================

    /// @notice Changes the amount that can be redistributed with this contract
    /// @param newAmountToRedistribute New amount that can be given by this contract
    /// @dev This function should typically be called after the settlement trigger and after this contract
    /// receives more collateral
    function setAmountToRedistribute(uint256 newAmountToRedistribute) external onlyRole(GOVERNOR_ROLE) onlyClaimPeriod {
        require(underlyingToken.balanceOf(address(this)) >= newAmountToRedistribute, "too high amount");
        amountToRedistribute = newAmountToRedistribute;

        emit AmountRedistributeUpdated(amountToRedistribute);
    }

    /// @notice Recovers leftover underlying token from the contract
    /// @param to Address to send the remaining tokens to
    /// @dev It can be used after the `setAmountToDistributeEach` function has been called to allocate
    /// the surplus of the contract elsewhere
    function recoverUnderlying(address to) external onlyRole(GOVERNOR_ROLE) onlyBaseAmountsComputed {
        require(amountToRedistribute > 0, "amount should be left to distribute");
        amountToRedistribute = 0;
        underlyingToken.safeTransfer(to, amountToRedistribute);
    }

    /// @notice Changes the proportion of governance tokens ratio that should be used to compute the claims
    /// with governance tokens
    /// @param _proportionalRatioGovUser New ratio for users
    /// @param _proportionalRatioGovLP New Ratio for LPs (both SLPs and HAs)
    /// @dev This function can only be called before the claim period and settlement trigger
    function setProportionalRatioGov(uint256 _proportionalRatioGovUser, uint256 _proportionalRatioGovLP)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        // There could be an attack if these ratios can be modified during the claim period
        require(startTimestamp == 0, "ratios cannot be modified after start");
        proportionalRatioGovUser = _proportionalRatioGovUser;
        proportionalRatioGovLP = _proportionalRatioGovLP;
        emit ProportionalRatioGovUpdated(proportionalRatioGovUser, proportionalRatioGovLP);
    }

    /// @notice Pauses pausable methods, that is all the claim and redeem methods
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /// @notice Unpauses paused methods
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============================= Internal Function =============================

    /// @notice Handles a claim after having computed the amount in collateral (`amountInC`) from the claim
    /// @param dest Address the claim will be for
    /// @param amountGovToken Amount of governance tokens sent
    /// @param amountInC Amount in collateral for the claim
    /// @param lp Whether the claim is a LP or a user claim
    /// @dev This function is called after the amount from a claim has been computed
    /// @dev It is at the level of this function that it is seen from the proportional ratios whether a claim is
    /// a preferable claim (involving governance tokens sent) or not
    function _treatClaim(
        address dest,
        uint256 amountGovToken,
        uint256 amountInC,
        uint256 lp
    ) internal {
        if (amountGovToken > 0) {
            // From the `amountGovToken`, computing the portion of the initial claim that is going to be
            // treated as a preferable claim
            uint256 amountInCGov;
            if (lp > 0) {
                amountInCGov = (amountGovToken * BASE) / proportionalRatioGovLP;
            } else {
                amountInCGov = (amountGovToken * BASE) / proportionalRatioGovUser;
            }
            if (amountInCGov > amountInC) {
                amountInCGov = amountInC;
            }
            amountInC -= amountInCGov;
            if (lp > 0) {
                totalLpClaimsWithGov += amountInCGov;
                lpClaimsWithGov[dest].govTokens += amountGovToken;
                lpClaimsWithGov[dest].claim += amountInCGov;
                emit LPClaimGovUpdated(totalLpClaimsWithGov);
            } else {
                totalUserClaimsWithGov += amountInCGov;
                userClaimsWithGov[dest].govTokens += amountGovToken;
                userClaimsWithGov[dest].claim += amountInCGov;
                emit UserClaimGovUpdated(totalUserClaimsWithGov);
            }
            angle.transferFrom(msg.sender, address(this), amountGovToken);
        }
        if (lp > 0) {
            totalLpClaims += amountInC;
            lpClaims[dest] += amountInC;
            emit LPClaimUpdated(totalLpClaims);
        } else {
            totalUserClaims += amountInC;
            userClaims[dest] += amountInC;
            emit UserClaimUpdated(totalUserClaims);
        }
    }
}
