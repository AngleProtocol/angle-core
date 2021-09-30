// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "./CollateralSettlerERC20Events.sol";

/// @title CollateralSettlerERC20
/// @author Angle Core Team
/// @notice A contract to settle the positions associated to a collateral for a given stablecoin
/// @dev In this contract the term LP refers to both SLPs and HAs
contract CollateralSettlerERC20 is CollateralSettlerERC20Events, ICollateralSettler, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for `StableMaster`. This role is also given to the governor addresses
    bytes32 public constant STABLEMASTER_ROLE = keccak256("STABLEMASTER_ROLE");
    /// @notice Base that is used to compute ratios and floating numbers
    uint256 public constant BASE_TOKENS = 10**18;
    /// @notice Base that is used to define parameters that have a floating value
    uint256 public constant BASE_PARAMS = 10**9;

    // Struct representing a claim that was made by sending governance tokens
    struct GovTokenClaim {
        // Number of gov tokens that is owed to users which claimed
        uint256 govTokens;
        // Value of the claim: this is the amount that is going to get treated preferably
        // For a user claim, the `claim` parameter is going to be expressed in stablecoin value
        // For a HA or LP claim, this parameter is going to be set in collateral value
        uint256 claim;
    }

    // =================== References to contracts =================================

    /// @notice Address of the `PerpetualManager` corresponding to the pool being closed
    IPerpetualManagerFront public immutable perpetualManager;

    /// @notice Address of the `SanToken` corresponding to the pool being closed
    ISanToken public immutable sanToken;

    /// @notice Address of the `AgToken` contract corresponding to the pool being closed
    IAgToken public immutable agToken;

    /// @notice Address of the `PoolManager` corresponding to the pool being closed
    IPoolManager public immutable poolManager;

    /// @notice Address of the corresponding ERC20 token
    IERC20 public immutable underlyingToken;

    /// @notice Governance token of the protocol
    /// It is stored here because users, HAs and SLPs can send governance tokens to get treated preferably
    /// in case of collateral settlement
    IERC20 public immutable angle;

    /// @notice Address of the Oracle contract corresponding to the pool being closed
    /// It is used to fetch the price at which stablecoins are going to be converted in collateral at the end
    /// of the settlement period
    IOracle public immutable oracle;

    // ========================= Activation Variables ==============================

    /// @notice Base used in the collateral implementation (ERC20 decimal)
    /// This parameter is set in the `constructor`
    uint256 public collatBase;

    /// @notice Value of the oracle at settlement trigger time
    /// It is the one that is used to compute HAs claims
    /// Note that the oracle value for HAs is going to be slightly different than that for users
    /// For HAs, it is as if at the time of trigger of collateral settlement, their positions were forced closed
    /// without needing to pay fees
    uint256 public oracleValueHA;

    /// @notice Value of the oracle at the end of the claim period. This is the value that is used to settle users
    /// The reason for using a different value than for HAs is that the real value of the oracle could change
    /// during the claim time. In case of the revokation of a single collateral, there could be, if we used the same value as HAs,
    /// arbitrages among users seeing that the value of the oracle at which they are going to be settled differ
    /// from the current oracle value. Or in case of multiple collaterals being revoked at the same time, users could see
    /// a bargain in a collateral and all come to redeem one collateral in particular
    uint256 public oracleValueUsers;

    /// @notice Exchange rate between sanTokens and collateral at settlement trigger time
    uint256 public sanRate;

    /// @notice Maximum number of stablecoins that can be claimed using this collateral type
    /// The reason for this parameter is that in case of generalized collateral settlement where all collateral types
    /// are settled, it prevents users from all claiming the same collateral thus penalizing HAs and SLPs of this
    /// collateral and advantaging HAs and SLPs of other collateral types.
    /// This parameter is set equal to the `stocksUsers` for this collateral type at the time of activation
    uint256 public maxStablecoinsClaimable;

    /// @notice Total amount of collateral to redistribute
    uint256 public amountToRedistribute;

    /// @notice Time at which settlement was triggered, initialized at zero
    uint256 public startTimestamp;

    // ======================= Accounting Variables ================================

    /// @notice Number used a boolean to see if the `setAmountToRedistributeEach` function
    /// has already been called
    /// @dev This function can only be called once throughout the lifetime of the contract
    uint256 public baseAmountToEachComputed;

    /// @notice Sum of the claims of users which did not bring governance tokens (expressed in stablecoin value)
    uint256 public totalUserClaims;

    /// @notice Sum of the claims of users which brought governance tokens (expressed in stablecoin value)
    uint256 public totalUserClaimsWithGov;

    /// @notice Sum of the claims from LPs (expressed in collateral value)
    uint256 public totalLpClaims;

    /// @notice Sum of the claims from LPs which had governance tokens (expressed in collateral value)
    uint256 public totalLpClaimsWithGov;

    /// @notice Ratio between what can be given and the claim for each user with gov tokens
    /// It is going to be updated (like the quantities below) only once at the end of the claim period
    uint64 public baseAmountToUserGov;

    /// @notice Ratio between what can be given and the claim for each user
    uint64 public baseAmountToUser;

    /// @notice Ratio between what can be given and the claim for each LP with gov tokens
    uint64 public baseAmountToLpGov;

    /// @notice Ratio between what can be given and the claim for each LP
    uint64 public baseAmountToLp;

    // ============================ Parameters =====================================

    /// @notice Used to compute the portion of the user claim that is going to be considered as a claim
    /// with governance tokens for a unit amount of governance tokens brought
    /// Attention, this ratio should be between an amount of governance tokens and an amout of stablecoins
    uint64 public proportionalRatioGovUser;

    /// @notice Used to compute the portion of the HA or SLP claim that is going to be considered as a claim
    /// with governance tokens for a unit amount of governance tokens brought
    uint64 public proportionalRatioGovLP;

    /// @notice Time after the trigger in which users and LPs can come and claim their collateral
    uint256 public claimTime;

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
            "57"
        );
        _;
    }

    /// @notice Checks to see if the base amounts to distribute to each category have already been computed
    /// @dev This allows to verify if users and LPs can redeem their collateral
    /// @dev As the `baseAmountToEachComputed` can only be changed from 0 during redeem period, this modifier
    /// allows at the same time to check if claim period is over
    modifier onlyBaseAmountsComputed() {
        require(baseAmountToEachComputed != 0, "58");
        _;
    }

    // =============================== Constructor =================================

    /// @notice Collateral settler constructor
    /// @param _poolManager Address of the corresponding `PoolManager`
    /// @param _angle Address of the ANGLE token
    /// @param _claimTime Duration in which users and LPs will be able to claim their collateral
    /// @param governorList List of the governor addresses of the protocol
    constructor(
        IPoolManager _poolManager,
        IERC20 _angle,
        uint256 _claimTime,
        address[] memory governorList
    ) {
        require(address(_angle) != address(0), "0");
        // Retrieving from the `_poolManager` all the correct references, this guarantees the integrity of the contract
        poolManager = _poolManager;
        perpetualManager = IPerpetualManagerFront(_poolManager.perpetualManager());
        address stableMaster = _poolManager.stableMaster();
        (, ISanToken _sanToken, , IOracle _oracle, , , uint256 _collatBase, , ) = IStableMaster(stableMaster)
            .collateralMap(_poolManager);
        sanToken = _sanToken;
        collatBase = _collatBase;
        oracle = _oracle;
        agToken = IAgToken(IStableMaster(stableMaster).agToken());
        underlyingToken = IERC20(_poolManager.token());
        angle = _angle;
        claimTime = _claimTime;

        // Access control
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "0");
            _setupRole(GOVERNOR_ROLE, governorList[i]);
            // Governors also have the `STABLEMASTER_ROLE` to allow them to trigger settlement directly
            _setupRole(STABLEMASTER_ROLE, governorList[i]);
        }
        _setupRole(STABLEMASTER_ROLE, stableMaster);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(STABLEMASTER_ROLE, GOVERNOR_ROLE);

        emit CollateralSettlerInit(address(_poolManager), address(_angle), claimTime);
    }

    // ========================== Contract Activation ==============================

    /// @notice Activates settlement for this contract, launches claim period and freezes oracle value for HAs
    /// @param _oracleValue Value of the oracle that will be used for the settlement to get the
    /// value of HAs positions. A different oracle value is going to be defined later to convert stablecoins to
    /// collateral for users
    /// @param _sanRate Value of the `sanRate` at time of settlement to be able to convert an amount of
    /// sanTokens to an amount of collateral
    /// @param _stocksUsers Maximum amount of stablecoins that will be redeemable by users for this collateral
    /// @dev This function is to be called by the `StableMaster` after governance called `revokeCollateral` or by
    /// governance directly, in which case governance will have to pay attention to pass the right values and to
    /// pause in the concerned `StableMaster` users, HAs and SLPs. In this situation, governance has more freedom
    /// regarding the oracle value at which settlement will occur
    /// @dev This function can only be called once throughout the contract's lifetime
    /// @dev It is preferable to set the different proportion ratios at collateral deployment or before any
    /// suspicion that triggerSettlement will be called to avoid front-running
    function triggerSettlement(
        uint256 _oracleValue,
        uint256 _sanRate,
        uint256 _stocksUsers
    ) external override onlyRole(STABLEMASTER_ROLE) {
        require(startTimestamp == 0, "59");
        require(proportionalRatioGovLP != 0 && proportionalRatioGovUser != 0, "60");
        oracleValueHA = _oracleValue;
        sanRate = _sanRate;
        maxStablecoinsClaimable = _stocksUsers;
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
        require(dest != address(0), "0");
        require(totalUserClaimsWithGov + totalUserClaims + amountAgToken <= maxStablecoinsClaimable, "61");
        // Since this involves a `transferFrom`, it is normal to update the variables after the transfers are done
        // No need to use `safeTransfer` for agTokens and ANGLE tokens
        agToken.transferFrom(msg.sender, address(this), amountAgToken);
        if (amountGovToken > 0) {
            angle.transferFrom(msg.sender, address(this), amountGovToken);
            // From the `amountGovToken`, computing the portion of the initial claim that is going to be
            // treated as a preferable claim
            uint256 amountAgTokenGov = (amountGovToken * BASE_PARAMS) / proportionalRatioGovUser;
            amountAgTokenGov = amountAgTokenGov > amountAgToken ? amountAgToken : amountAgTokenGov;
            amountAgToken -= amountAgTokenGov;
            totalUserClaimsWithGov += amountAgTokenGov;
            userClaimsWithGov[dest].govTokens += amountGovToken;
            userClaimsWithGov[dest].claim += amountAgTokenGov;
            emit UserClaimGovUpdated(totalUserClaimsWithGov);
        }
        // The claims for users are stored in stablecoin value: conversion will be done later on at the end on
        // the claim period
        totalUserClaims += amountAgToken;
        userClaims[dest] += amountAgToken;
        emit UserClaimUpdated(totalUserClaims);
    }

    // =============================== HA Claims ===================================

    /// @notice Allows a HA to claim collateral by sending a `perpetualID` and gov tokens (optional)
    /// @param perpetualID Perpetual owned by the HA
    /// @param amountGovToken Amount of governance sent
    /// @dev The contract automatically recognizes the beneficiary of the perpetual
    /// @dev If the perpetual of the HA should be liquidated then, this HA will not be able to get
    /// a claim on the remaining collateral
    function claimHA(uint256 perpetualID, uint256 amountGovToken) external onlyClaimPeriod whenNotPaused {
        require(perpetualManager.isApprovedOrOwner(msg.sender, perpetualID), "21");
        // Getting the owner of the perpetual
        // The zero address cannot own a perpetual
        address dest = perpetualManager.ownerOf(perpetualID);
        require(haClaimCheck[perpetualID] == 0, "64");
        // A HA cannot claim a given perpetual twice
        haClaimCheck[perpetualID] = 1;
        // Computing the amount of the claim from the perpetual
        (uint256 amountInC, uint256 reachMaintenanceMargin) = perpetualManager.getCashOutAmount(
            perpetualID,
            oracleValueHA
        );
        // If the perpetual is below the maintenance margin, then the claim of the HA is null
        if (reachMaintenanceMargin != 1 && amountInC > 0) {
            // Updating the contract's mappings accordingly
            _treatLPClaim(dest, amountGovToken, amountInC);
        }
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
        require(dest != address(0), "0");
        sanToken.transferFrom(msg.sender, address(this), amountSanToken);
        // Computing the amount of the claim from the number of sanTokens sent
        uint256 amountInC = (amountSanToken * sanRate) / BASE_TOKENS;
        // Updating the contract's mappings accordingly
        _treatLPClaim(dest, amountGovToken, amountInC);
    }

    // ========================= Redeem Period =====================================

    /// @notice Computes the base amount each category of claim will get after the claim period has ended
    /// @dev This function can only be called once when claim period is over
    /// @dev It is at the level of this function that the waterfall between the different
    /// categories of stakeholders and of claims is executed
    function setAmountToRedistributeEach() external whenNotPaused {
        // Checking if it is the right time to call the function: claim period should be over
        require(startTimestamp != 0 && block.timestamp > claimTime + startTimestamp, "63");
        // This is what guarantees that this function can only be computed once
        require(baseAmountToEachComputed == 0, "62");
        baseAmountToEachComputed = 1;
        // Fetching the oracle value at which stablecoins will be converted to collateral
        oracleValueUsers = oracle.readLower();
        // The waterfall first gives everything that's possible to stable holders which had governance tokens
        // in the limit of what is owed to them
        // We need to convert the user claims expressed in stablecoin value to claims in collateral value
        uint256 totalUserClaimsWithGovInC = (totalUserClaimsWithGov * collatBase) / oracleValueUsers;
        uint256 totalUserClaimsInC = (totalUserClaims * collatBase) / oracleValueUsers;
        if (amountToRedistribute >= totalUserClaimsWithGovInC) {
            baseAmountToUserGov = uint64(BASE_PARAMS);
            amountToRedistribute -= totalUserClaimsWithGovInC;
        } else {
            baseAmountToUserGov = uint64((amountToRedistribute * BASE_PARAMS) / totalUserClaimsWithGovInC);
            amountToRedistribute = 0;
        }
        // Then it gives everything that remains to other stable holders (in the limit of what is owed to them)
        if (amountToRedistribute > totalUserClaimsInC) {
            baseAmountToUser = uint64(BASE_PARAMS);
            amountToRedistribute -= totalUserClaimsInC;
        } else {
            baseAmountToUser = uint64((amountToRedistribute * BASE_PARAMS) / totalUserClaimsInC);
            amountToRedistribute = 0;
        }
        // After that, LPs which had governance tokens claims are going to be treated: once again the contract
        // gives them everything it can in the limit of their claim
        if (amountToRedistribute > totalLpClaimsWithGov) {
            baseAmountToLpGov = uint64(BASE_PARAMS);
            amountToRedistribute -= totalLpClaimsWithGov;
        } else {
            baseAmountToLpGov = uint64((amountToRedistribute * BASE_PARAMS) / totalLpClaimsWithGov);
            amountToRedistribute = 0;
        }
        // And last, LPs claims without governance tokens are handled
        if (amountToRedistribute > totalLpClaims) {
            baseAmountToLp = uint64(BASE_PARAMS);
            amountToRedistribute -= totalLpClaims;
        } else {
            baseAmountToLp = uint64((amountToRedistribute * BASE_PARAMS) / totalLpClaims);
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
        // Converting the claims stored for each user in collateral value
        uint256 amountToGive = ((userClaimsWithGov[user].claim * collatBase * baseAmountToUserGov) /
            oracleValueUsers +
            (userClaims[user] * collatBase * baseAmountToUser) /
            oracleValueUsers +
            lpClaimsWithGov[user].claim *
            baseAmountToLpGov +
            lpClaims[user] *
            baseAmountToLp) / BASE_PARAMS;
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
        require(underlyingToken.balanceOf(address(this)) >= newAmountToRedistribute, "66");
        amountToRedistribute = newAmountToRedistribute;

        emit AmountRedistributeUpdated(amountToRedistribute);
    }

    /// @notice Recovers leftover tokens from the contract or tokens that were mistakenly sent to the contract
    /// @param tokenAddress Address of the token to recover
    /// @param to Address to send the remaining tokens to
    /// @param amountToRecover Amount to recover from the contract
    /// @dev It can be used after the `setAmountToDistributeEach` function has been called to allocate
    /// the surplus of the contract elsewhere
    /// @dev It can also be used to recover tokens that are mistakenly sent to this contract
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amountToRecover
    ) external onlyRole(GOVERNOR_ROLE) onlyBaseAmountsComputed {
        if (tokenAddress == address(underlyingToken)) {
            require(amountToRedistribute >= amountToRecover, "66");
            amountToRedistribute -= amountToRecover;
            underlyingToken.safeTransfer(to, amountToRecover);
        } else {
            IERC20(tokenAddress).safeTransfer(to, amountToRecover);
        }
        emit Recovered(tokenAddress, to, amountToRecover);
    }

    /// @notice Changes the governance tokens proportionality ratio used to compute the claims
    /// with governance tokens
    /// @param _proportionalRatioGovUser New ratio for users
    /// @param _proportionalRatioGovLP New ratio for LPs (both SLPs and HAs)
    /// @dev This function can only be called before the claim period and settlement trigger: there could be
    /// a governance attack if these ratios can be modified during the claim period
    function setProportionalRatioGov(uint64 _proportionalRatioGovUser, uint64 _proportionalRatioGovLP)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(startTimestamp == 0, "65");
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
    /// for a SLP or a HA
    /// @param dest Address the claim will be for
    /// @param amountGovToken Amount of governance tokens sent
    /// @param amountInC Amount in collateral for the claim
    /// @dev This function is called after the amount from a claim has been computed
    /// @dev It is at the level of this function that it is seen from the proportional ratios whether a LP claim is
    /// a preferable claim (involving governance tokens sent) or not
    function _treatLPClaim(
        address dest,
        uint256 amountGovToken,
        uint256 amountInC
    ) internal {
        if (amountGovToken > 0) {
            angle.transferFrom(msg.sender, address(this), amountGovToken);
            uint256 amountInCGov = (amountGovToken * BASE_PARAMS) / proportionalRatioGovLP;
            amountInCGov = amountInCGov > amountInC ? amountInC : amountInCGov;
            amountInC -= amountInCGov;
            totalLpClaimsWithGov += amountInCGov;
            lpClaimsWithGov[dest].govTokens += amountGovToken;
            lpClaimsWithGov[dest].claim += amountInCGov;
            emit LPClaimGovUpdated(totalLpClaimsWithGov);
        }
        totalLpClaims += amountInC;
        lpClaims[dest] += amountInC;
        emit LPClaimUpdated(totalLpClaims);
    }
}
