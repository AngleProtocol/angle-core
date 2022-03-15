// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IFeeDistributor.sol";
import "../interfaces/ILiquidityGauge.sol";
import "../interfaces/ISanToken.sol";
import "../interfaces/IStableMaster.sol";
import "../interfaces/IStableMasterFront.sol";
import "../interfaces/IVeANGLE.sol";
import "../interfaces/external/IWETH9.sol";
import "../interfaces/external/uniswap/IUniswapRouter.sol";

/// @title AngleRouter
/// @author Angle Core Team
/// @notice The `AngleRouter` contract facilitates interactions for users with the protocol. It was built to reduce the number
/// of approvals required to users and the number of transactions needed to perform some complex actions: like deposit and stake
/// in just one transaction
/// @dev Interfaces were designed for both advanced users which know the addresses of the protocol's contract, but most of the time
/// users which only know addresses of the stablecoins and collateral types of the protocol can perform the actions they want without
/// needing to understand what's happening under the hood
contract AngleRouter is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    /// @notice Base used for params
    uint256 public constant BASE_PARAMS = 10**9;

    /// @notice Base used for params
    uint256 private constant _MAX_TOKENS = 10;
    // @notice Wrapped ETH contract
    IWETH9 public constant WETH9 = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // @notice ANGLE contract
    IERC20 public constant ANGLE = IERC20(0x31429d1856aD1377A8A0079410B297e1a9e214c2);
    // @notice veANGLE contract
    IVeANGLE public constant VEANGLE = IVeANGLE(0x0C462Dbb9EC8cD1630f1728B2CFD2769d09f0dd5);

    // =========================== Structs and Enums ===============================

    /// @notice Action types
    enum ActionType {
        claimRewards,
        claimWeeklyInterest,
        gaugeDeposit,
        withdraw,
        mint,
        deposit,
        openPerpetual,
        addToPerpetual,
        veANGLEDeposit
    }

    /// @notice All possible swaps
    enum SwapType {
        UniswapV3,
        oneINCH
    }

    /// @notice Params for swaps
    /// @param inToken Token to swap
    /// @param collateral Token to swap for
    /// @param amountIn Amount of token to sell
    /// @param minAmountOut Minimum amount of collateral to receive for the swap to not revert
    /// @param args Either the path for Uniswap or the payload for 1Inch
    /// @param swapType Which swap route to take
    struct ParamsSwapType {
        IERC20 inToken;
        address collateral;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes args;
        SwapType swapType;
    }

    /// @notice Params for direct collateral transfer
    /// @param inToken Token to transfer
    /// @param amountIn Amount of token transfer
    struct TransferType {
        IERC20 inToken;
        uint256 amountIn;
    }

    /// @notice References to the contracts associated to a collateral for a stablecoin
    struct Pairs {
        IPoolManager poolManager;
        IPerpetualManagerFrontWithClaim perpetualManager;
        ISanToken sanToken;
        ILiquidityGauge gauge;
    }

    /// @notice Data needed to get permits
    struct PermitType {
        address token;
        address owner;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // =============================== Events ======================================

    event AdminChanged(address indexed admin, bool setGovernor);
    event StablecoinAdded(address indexed stableMaster);
    event StablecoinRemoved(address indexed stableMaster);
    event CollateralToggled(address indexed stableMaster, address indexed poolManager, address indexed liquidityGauge);
    event SanTokenLiquidityGaugeUpdated(address indexed sanToken, address indexed newLiquidityGauge);
    event Recovered(address indexed tokenAddress, address indexed to, uint256 amount);

    // =============================== Mappings ====================================

    /// @notice Maps an agToken to its counterpart `StableMaster`
    mapping(IERC20 => IStableMasterFront) public mapStableMasters;
    /// @notice Maps a `StableMaster` to a mapping of collateral token to its counterpart `PoolManager`
    mapping(IStableMasterFront => mapping(IERC20 => Pairs)) public mapPoolManagers;
    /// @notice Whether the token was already approved on Uniswap router
    mapping(IERC20 => bool) public uniAllowedToken;
    /// @notice Whether the token was already approved on 1Inch
    mapping(IERC20 => bool) public oneInchAllowedToken;

    // =============================== References ==================================

    /// @notice Governor address
    address public governor;
    /// @notice Guardian address
    address public guardian;
    /// @notice Address of the router used for swaps
    IUniswapV3Router public uniswapV3Router;
    /// @notice Address of 1Inch router used for swaps
    address public oneInch;

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice Deploys the `AngleRouter` contract
    /// @param _governor Governor address
    /// @param _guardian Guardian address
    /// @param _uniswapV3Router UniswapV3 router address
    /// @param _oneInch 1Inch aggregator address
    /// @param existingStableMaster Address of the existing `StableMaster`
    /// @param existingPoolManagers Addresses of the associated poolManagers
    /// @param existingLiquidityGauges Addresses of liquidity gauge contracts associated to sanTokens
    /// @dev Be cautious with safe approvals, all tokens will have unlimited approvals within the protocol or
    /// UniswapV3 and 1Inch
    function initialize(
        address _governor,
        address _guardian,
        IUniswapV3Router _uniswapV3Router,
        address _oneInch,
        IStableMasterFront existingStableMaster,
        IPoolManager[] calldata existingPoolManagers,
        ILiquidityGauge[] calldata existingLiquidityGauges
    ) public initializer {
        // Checking the parameters passed
        require(
            address(_uniswapV3Router) != address(0) &&
                _oneInch != address(0) &&
                _governor != address(0) &&
                _guardian != address(0),
            "0"
        );
        require(_governor != _guardian, "49");
        require(existingPoolManagers.length == existingLiquidityGauges.length, "104");
        // Fetching the stablecoin and mapping it to the `StableMaster`
        mapStableMasters[
            IERC20(address(IStableMaster(address(existingStableMaster)).agToken()))
        ] = existingStableMaster;
        // Setting roles
        governor = _governor;
        guardian = _guardian;
        uniswapV3Router = _uniswapV3Router;
        oneInch = _oneInch;

        // for veANGLEDeposit action
        ANGLE.safeApprove(address(VEANGLE), type(uint256).max);

        for (uint256 i = 0; i < existingPoolManagers.length; i++) {
            _addPair(existingStableMaster, existingPoolManagers[i], existingLiquidityGauges[i]);
        }
    }

    // ============================== Modifiers ====================================

    /// @notice Checks to see if it is the `governor` or `guardian` calling this contract
    /// @dev There is no Access Control here, because it can be handled cheaply through this modifier
    /// @dev In this contract, the `governor` and the `guardian` address have exactly similar rights
    modifier onlyGovernorOrGuardian() {
        require(msg.sender == governor || msg.sender == guardian, "115");
        _;
    }

    // =========================== Governance utilities ============================

    /// @notice Changes the guardian or the governor address
    /// @param admin New guardian or guardian address
    /// @param setGovernor Whether to set Governor if true, or Guardian if false
    /// @dev There can only be one guardian and one governor address in the router
    /// and both need to be different
    function setGovernorOrGuardian(address admin, bool setGovernor) external onlyGovernorOrGuardian {
        require(admin != address(0), "0");
        require(guardian != admin && governor != admin, "49");
        if (setGovernor) governor = admin;
        else guardian = admin;
        emit AdminChanged(admin, setGovernor);
    }

    /// @notice Adds a new `StableMaster`
    /// @param stablecoin Address of the new stablecoin
    /// @param stableMaster Address of the new `StableMaster`
    function addStableMaster(IERC20 stablecoin, IStableMasterFront stableMaster) external onlyGovernorOrGuardian {
        // No need to check if the `stableMaster` address is a zero address as otherwise the call to `stableMaster.agToken()`
        // would revert
        require(address(stablecoin) != address(0), "0");
        require(address(mapStableMasters[stablecoin]) == address(0), "114");
        require(stableMaster.agToken() == address(stablecoin), "20");
        mapStableMasters[stablecoin] = stableMaster;
        emit StablecoinAdded(address(stableMaster));
    }

    /// @notice Removes a `StableMaster`
    /// @param stablecoin Address of the associated stablecoin
    /// @dev Before calling this function, governor or guardian should remove first all pairs
    /// from the `mapPoolManagers[stableMaster]`. It is assumed that the governor or guardian calling this function
    /// will act correctly here, it indeed avoids storing a list of all pairs for each `StableMaster`
    function removeStableMaster(IERC20 stablecoin) external onlyGovernorOrGuardian {
        IStableMasterFront stableMaster = mapStableMasters[stablecoin];
        delete mapStableMasters[stablecoin];
        emit StablecoinRemoved(address(stableMaster));
    }

    /// @notice Adds new collateral types to specific stablecoins
    /// @param stablecoins Addresses of the stablecoins associated to the `StableMaster` of interest
    /// @param poolManagers Addresses of the `PoolManager` contracts associated to the pair (stablecoin,collateral)
    /// @param liquidityGauges Addresses of liquidity gauges contract associated to sanToken
    function addPairs(
        IERC20[] calldata stablecoins,
        IPoolManager[] calldata poolManagers,
        ILiquidityGauge[] calldata liquidityGauges
    ) external onlyGovernorOrGuardian {
        require(poolManagers.length == stablecoins.length && liquidityGauges.length == stablecoins.length, "104");
        for (uint256 i = 0; i < stablecoins.length; i++) {
            IStableMasterFront stableMaster = mapStableMasters[stablecoins[i]];
            _addPair(stableMaster, poolManagers[i], liquidityGauges[i]);
        }
    }

    /// @notice Removes collateral types from specific `StableMaster` contracts using the address
    /// of the associated stablecoins
    /// @param stablecoins Addresses of the stablecoins
    /// @param collaterals Addresses of the collaterals
    /// @param stableMasters List of the associated `StableMaster` contracts
    /// @dev In the lists, if a `stableMaster` address is null in `stableMasters` then this means that the associated
    /// `stablecoins` address (at the same index) should be non null
    function removePairs(
        IERC20[] calldata stablecoins,
        IERC20[] calldata collaterals,
        IStableMasterFront[] calldata stableMasters
    ) external onlyGovernorOrGuardian {
        require(collaterals.length == stablecoins.length && stableMasters.length == collaterals.length, "104");
        Pairs memory pairs;
        IStableMasterFront stableMaster;
        for (uint256 i = 0; i < stablecoins.length; i++) {
            if (address(stableMasters[i]) == address(0))
                // In this case `collaterals[i]` is a collateral address
                (stableMaster, pairs) = _getInternalContracts(stablecoins[i], collaterals[i]);
            else {
                // In this case `collaterals[i]` is a `PoolManager` address
                stableMaster = stableMasters[i];
                pairs = mapPoolManagers[stableMaster][collaterals[i]];
            }
            delete mapPoolManagers[stableMaster][collaterals[i]];
            _changeAllowance(collaterals[i], address(stableMaster), 0);
            _changeAllowance(collaterals[i], address(pairs.perpetualManager), 0);
            if (address(pairs.gauge) != address(0)) pairs.sanToken.approve(address(pairs.gauge), 0);
            emit CollateralToggled(address(stableMaster), address(pairs.poolManager), address(pairs.gauge));
        }
    }

    /// @notice Sets new `liquidityGauge` contract for the associated sanTokens
    /// @param stablecoins Addresses of the stablecoins
    /// @param collaterals Addresses of the collaterals
    /// @param newLiquidityGauges Addresses of the new liquidity gauges contract
    /// @dev If `newLiquidityGauge` is null, this means that there is no liquidity gauge for this pair
    /// @dev This function could be used to simply revoke the approval to a liquidity gauge
    function setLiquidityGauges(
        IERC20[] calldata stablecoins,
        IERC20[] calldata collaterals,
        ILiquidityGauge[] calldata newLiquidityGauges
    ) external onlyGovernorOrGuardian {
        require(collaterals.length == stablecoins.length && newLiquidityGauges.length == stablecoins.length, "104");
        for (uint256 i = 0; i < stablecoins.length; i++) {
            IStableMasterFront stableMaster = mapStableMasters[stablecoins[i]];
            Pairs storage pairs = mapPoolManagers[stableMaster][collaterals[i]];
            ILiquidityGauge gauge = pairs.gauge;
            ISanToken sanToken = pairs.sanToken;
            require(address(stableMaster) != address(0) && address(pairs.poolManager) != address(0), "0");
            pairs.gauge = newLiquidityGauges[i];
            if (address(gauge) != address(0)) {
                sanToken.approve(address(gauge), 0);
            }
            if (address(newLiquidityGauges[i]) != address(0)) {
                // Checking compatibility of the staking token: it should be the sanToken
                require(address(newLiquidityGauges[i].staking_token()) == address(sanToken), "20");
                sanToken.approve(address(newLiquidityGauges[i]), type(uint256).max);
            }
            emit SanTokenLiquidityGaugeUpdated(address(sanToken), address(newLiquidityGauges[i]));
        }
    }

    /// @notice Change allowance for a contract.
    /// @param tokens Addresses of the tokens to allow
    /// @param spenders Addresses to allow transfer
    /// @param amounts Amounts to allow
    /// @dev Approvals are normally given in the `addGauges` method, in the initializer and in
    /// the internal functions to process swaps with Uniswap and 1Inch
    function changeAllowance(
        IERC20[] calldata tokens,
        address[] calldata spenders,
        uint256[] calldata amounts
    ) external onlyGovernorOrGuardian {
        require(tokens.length == spenders.length && tokens.length == amounts.length, "104");
        for (uint256 i = 0; i < tokens.length; i++) {
            _changeAllowance(tokens[i], spenders[i], amounts[i]);
        }
    }

    /// @notice Supports recovering any tokens as the router does not own any other tokens than
    /// the one mistakenly sent
    /// @param tokenAddress Address of the token to transfer
    /// @param to Address to give tokens to
    /// @param tokenAmount Amount of tokens to transfer
    /// @dev If tokens are mistakenly sent to this contract, any address can take advantage of the `mixer` function
    /// below to get the funds back
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 tokenAmount
    ) external onlyGovernorOrGuardian {
        IERC20(tokenAddress).safeTransfer(to, tokenAmount);
        emit Recovered(tokenAddress, to, tokenAmount);
    }

    // =========================== Router Functionalities =========================

    /// @notice Wrapper n°1 built on top of the _claimRewards function
    /// Allows to claim rewards for multiple gauges and perpetuals at once
    /// @param gaugeUser Address for which to fetch the rewards from the gauges
    /// @param liquidityGauges Gauges to claim on
    /// @param perpetualIDs Perpetual IDs to claim rewards for
    /// @param stablecoins Stablecoin contracts linked to the perpetualsIDs
    /// @param collaterals Collateral contracts linked to the perpetualsIDs or `perpetualManager`
    /// @dev If the caller wants to send the rewards to another account it first needs to
    /// call `set_rewards_receiver(otherAccount)` on each `liquidityGauge`
    function claimRewards(
        address gaugeUser,
        address[] memory liquidityGauges,
        uint256[] memory perpetualIDs,
        address[] memory stablecoins,
        address[] memory collaterals
    ) external nonReentrant {
        _claimRewards(gaugeUser, liquidityGauges, perpetualIDs, false, stablecoins, collaterals);
    }

    /// @notice Wrapper n°2 (a little more gas efficient than n°1) built on top of the _claimRewards function
    /// Allows to claim rewards for multiple gauges and perpetuals at once
    /// @param user Address to which the contract should send the rewards from gauges (not perpetuals)
    /// @param liquidityGauges Contracts to claim for
    /// @param perpetualIDs Perpetual IDs to claim rewards for
    /// @param perpetualManagers `perpetualManager` contracts for every perp to claim
    /// @dev If the caller wants to send the rewards to another account it first needs to
    /// call `set_rewards_receiver(otherAccount)` on each `liquidityGauge`
    function claimRewards(
        address user,
        address[] memory liquidityGauges,
        uint256[] memory perpetualIDs,
        address[] memory perpetualManagers
    ) external nonReentrant {
        _claimRewards(user, liquidityGauges, perpetualIDs, true, new address[](perpetualIDs.length), perpetualManagers);
    }

    /// @notice Wrapper built on top of the `_gaugeDeposit` method to deposit collateral in a gauge
    /// @param token On top of the parameters of the internal function, users need to specify the token associated
    /// to the gauge they want to deposit in
    /// @dev The function will revert if the token does not correspond to the gauge
    function gaugeDeposit(
        address user,
        uint256 amount,
        ILiquidityGauge gauge,
        bool shouldClaimRewards,
        IERC20 token
    ) external nonReentrant {
        token.safeTransferFrom(msg.sender, address(this), amount);
        _gaugeDeposit(user, amount, gauge, shouldClaimRewards);
    }

    /// @notice Wrapper n°1 built on top of the `_mint` method to mint stablecoins
    /// @param user Address to send the stablecoins to
    /// @param amount Amount of collateral to use for the mint
    /// @param minStableAmount Minimum stablecoin minted for the tx not to revert
    /// @param stablecoin Address of the stablecoin to mint
    /// @param collateral Collateral to mint from
    function mint(
        address user,
        uint256 amount,
        uint256 minStableAmount,
        address stablecoin,
        address collateral
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        _mint(user, amount, minStableAmount, false, stablecoin, collateral, IPoolManager(address(0)));
    }

    /// @notice Wrapper n°2 (a little more gas efficient than n°1) built on top of the `_mint` method to mint stablecoins
    /// @param user Address to send the stablecoins to
    /// @param amount Amount of collateral to use for the mint
    /// @param minStableAmount Minimum stablecoin minted for the tx not to revert
    /// @param stableMaster Address of the stableMaster managing the stablecoin to mint
    /// @param collateral Collateral to mint from
    /// @param poolManager PoolManager associated to the `collateral`
    function mint(
        address user,
        uint256 amount,
        uint256 minStableAmount,
        address stableMaster,
        address collateral,
        address poolManager
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        _mint(user, amount, minStableAmount, true, stableMaster, collateral, IPoolManager(poolManager));
    }

    /// @notice Wrapper built on top of the `_burn` method to burn stablecoins
    /// @param dest Address to send the collateral to
    /// @param amount Amount of stablecoins to use for the burn
    /// @param minCollatAmount Minimum collateral amount received for the tx not to revert
    /// @param stablecoin Address of the stablecoin to burn
    /// @param collateral Collateral to burn to
    function burn(
        address dest,
        uint256 amount,
        uint256 minCollatAmount,
        address stablecoin,
        address collateral
    ) external nonReentrant {
        _burn(dest, amount, minCollatAmount, false, stablecoin, collateral, IPoolManager(address(0)));
    }

    /// @notice Wrapper n°1 built on top of the `_deposit` method to deposit collateral as a SLP in the protocol
    /// Allows to deposit a collateral within the protocol
    /// @param user Address where to send the resulting sanTokens, if this address is the router address then it means
    /// that the intention is to stake the sanTokens obtained in a subsequent `gaugeDeposit` action
    /// @param amount Amount of collateral to deposit
    /// @param stablecoin `StableMaster` associated to the sanToken
    /// @param collateral Token to deposit
    /// @dev Contrary to the `mint` action, the `deposit` action can be used in composition with other actions, like
    /// `deposit` and then `stake
    function deposit(
        address user,
        uint256 amount,
        address stablecoin,
        address collateral
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(user, amount, false, stablecoin, collateral, IPoolManager(address(0)), ISanToken(address(0)));
    }

    /// @notice Wrapper n°2 (a little more gas efficient than n°1) built on top of the `_deposit` method to deposit collateral as a SLP in the protocol
    /// Allows to deposit a collateral within the protocol
    /// @param user Address where to send the resulting sanTokens, if this address is the router address then it means
    /// that the intention is to stake the sanTokens obtained in a subsequent `gaugeDeposit` action
    /// @param amount Amount of collateral to deposit
    /// @param stableMaster `StableMaster` associated to the sanToken
    /// @param collateral Token to deposit
    /// @param poolManager PoolManager associated to the sanToken
    /// @param sanToken SanToken associated to the `collateral` and `stableMaster`
    /// @dev Contrary to the `mint` action, the `deposit` action can be used in composition with other actions, like
    /// `deposit` and then `stake`
    function deposit(
        address user,
        uint256 amount,
        address stableMaster,
        address collateral,
        IPoolManager poolManager,
        ISanToken sanToken
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(user, amount, true, stableMaster, collateral, poolManager, sanToken);
    }

    /// @notice Wrapper built on top of the `_openPerpetual` method to open a perpetual with the protocol
    /// @param collateral Here the collateral should not be null (even if `addressProcessed` is true) for the router
    /// to be able to know how to deposit collateral
    /// @dev `stablecoinOrPerpetualManager` should be the address of the agToken (= stablecoin) is `addressProcessed` is false
    ///  and the associated `perpetualManager` otherwise
    function openPerpetual(
        address owner,
        uint256 margin,
        uint256 amountCommitted,
        uint256 maxOracleRate,
        uint256 minNetMargin,
        bool addressProcessed,
        address stablecoinOrPerpetualManager,
        address collateral
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), margin);
        _openPerpetual(
            owner,
            margin,
            amountCommitted,
            maxOracleRate,
            minNetMargin,
            addressProcessed,
            stablecoinOrPerpetualManager,
            collateral
        );
    }

    /// @notice Wrapper built on top of the `_addToPerpetual` method to add collateral to a perpetual with the protocol
    /// @param collateral Here the collateral should not be null (even if `addressProcessed is true) for the router
    /// to be able to know how to deposit collateral
    /// @dev `stablecoinOrPerpetualManager` should be the address of the agToken is `addressProcessed` is false and the associated
    /// `perpetualManager` otherwise
    function addToPerpetual(
        uint256 margin,
        uint256 perpetualID,
        bool addressProcessed,
        address stablecoinOrPerpetualManager,
        address collateral
    ) external nonReentrant {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), margin);
        _addToPerpetual(margin, perpetualID, addressProcessed, stablecoinOrPerpetualManager, collateral);
    }

    /// @notice Allows composable calls to different functions within the protocol
    /// @param paramsPermit Array of params `PermitType` used to do a 1 tx to approve the router on each token (can be done once by
    /// setting high approved amounts) which supports the `permit` standard. Users willing to interact with the contract
    /// with tokens that do not support permit should approve the contract for these tokens prior to interacting with it
    /// @param paramsTransfer Array of params `TransferType` used to transfer tokens to the router
    /// @param paramsSwap Array of params `ParamsSwapType` used to swap tokens
    /// @param actions List of actions to be performed by the router (in order of execution): make sure to read for each action the
    /// associated internal function
    /// @param datas Array of encoded data for each of the actions performed in this mixer. This is where the bytes-encoded parameters
    /// for a given action are stored
    /// @dev This function first fills the router balances via transfers and swaps. It then proceeds with each
    /// action in the order at which they are given
    /// @dev With this function, users can specify paths to swap tokens to the desired token of their choice. Yet the protocol
    /// does not verify the payload given and cannot check that the swap performed by users actually gives the desired
    /// out token: in this case funds will be lost by the user
    /// @dev For some actions (`mint`, `deposit`, `openPerpetual`, `addToPerpetual`, `withdraw`), users are
    /// required to give a proportion of the amount of token they have brought to the router within the transaction (through
    /// a direct transfer or a swap) they want to use for the operation. If you want to use all the USDC you have brought (through an ETH -> USDC)
    /// swap to mint stablecoins for instance, you should use `BASE_PARAMS` as a proportion.
    /// @dev The proportion that is specified for an action is a proportion of what is left. If you want to use 50% of your USDC for a `mint`
    /// and the rest for an `openPerpetual`, proportion used for the `mint` should be 50% (that is `BASE_PARAMS/2`), and proportion
    /// for the `openPerpetual` should be all that is left that is 100% (= `BASE_PARAMS`).
    /// @dev For each action here, make sure to read the documentation of the associated internal function to know how to correctly
    /// specify parameters
    function mixer(
        PermitType[] memory paramsPermit,
        TransferType[] memory paramsTransfer,
        ParamsSwapType[] memory paramsSwap,
        ActionType[] memory actions,
        bytes[] calldata datas
    ) external payable nonReentrant {
        // Do all the permits once for all: if all tokens have already been approved, there's no need for this step
        for (uint256 i = 0; i < paramsPermit.length; i++) {
            IERC20PermitUpgradeable(paramsPermit[i].token).permit(
                paramsPermit[i].owner,
                address(this),
                paramsPermit[i].value,
                paramsPermit[i].deadline,
                paramsPermit[i].v,
                paramsPermit[i].r,
                paramsPermit[i].s
            );
        }

        // Then, do all the transfer to load all needed funds into the router
        // This function is limited to 10 different assets to be spent on the protocol (agTokens, collaterals, sanTokens)
        address[_MAX_TOKENS] memory listTokens;
        uint256[_MAX_TOKENS] memory balanceTokens;

        for (uint256 i = 0; i < paramsTransfer.length; i++) {
            paramsTransfer[i].inToken.safeTransferFrom(msg.sender, address(this), paramsTransfer[i].amountIn);
            _addToList(listTokens, balanceTokens, address(paramsTransfer[i].inToken), paramsTransfer[i].amountIn);
        }

        for (uint256 i = 0; i < paramsSwap.length; i++) {
            // Caution here: if the args are not set such that end token is the params `paramsSwap[i].collateral`,
            // then the funds will be lost, and any user could take advantage of it to fetch the funds
            uint256 amountOut = _transferAndSwap(
                paramsSwap[i].inToken,
                paramsSwap[i].amountIn,
                paramsSwap[i].minAmountOut,
                paramsSwap[i].swapType,
                paramsSwap[i].args
            );
            _addToList(listTokens, balanceTokens, address(paramsSwap[i].collateral), amountOut);
        }

        // Performing actions one after the others
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i] == ActionType.claimRewards) {
                (
                    address user,
                    uint256 proportionToBeTransferred,
                    address[] memory claimLiquidityGauges,
                    uint256[] memory claimPerpetualIDs,
                    bool addressProcessed,
                    address[] memory stablecoins,
                    address[] memory collateralsOrPerpetualManagers
                ) = abi.decode(datas[i], (address, uint256, address[], uint256[], bool, address[], address[]));

                uint256 amount = ANGLE.balanceOf(user);

                _claimRewards(
                    user,
                    claimLiquidityGauges,
                    claimPerpetualIDs,
                    addressProcessed,
                    stablecoins,
                    collateralsOrPerpetualManagers
                );
                if (proportionToBeTransferred > 0) {
                    amount = ANGLE.balanceOf(user) - amount;
                    amount = (amount * proportionToBeTransferred) / BASE_PARAMS;
                    ANGLE.safeTransferFrom(msg.sender, address(this), amount);
                    _addToList(listTokens, balanceTokens, address(ANGLE), amount);
                }
            } else if (actions[i] == ActionType.claimWeeklyInterest) {
                (address user, address feeDistributor, bool letInContract) = abi.decode(
                    datas[i],
                    (address, address, bool)
                );

                (uint256 amount, IERC20 token) = _claimWeeklyInterest(
                    user,
                    IFeeDistributorFront(feeDistributor),
                    letInContract
                );
                if (address(token) != address(0)) _addToList(listTokens, balanceTokens, address(token), amount);
                // In all the following action, the `amount` variable represents the proportion of the
                // balance that needs to be used for this action (in `BASE_PARAMS`)
                // We name it `amount` here to save some new variable declaration costs
            } else if (actions[i] == ActionType.veANGLEDeposit) {
                (address user, uint256 amount) = abi.decode(datas[i], (address, uint256));

                amount = _computeProportion(amount, listTokens, balanceTokens, address(ANGLE));
                _depositOnLocker(user, amount);
            } else if (actions[i] == ActionType.gaugeDeposit) {
                (address user, uint256 amount, address stakedToken, address gauge, bool shouldClaimRewards) = abi
                    .decode(datas[i], (address, uint256, address, address, bool));

                amount = _computeProportion(amount, listTokens, balanceTokens, stakedToken);
                _gaugeDeposit(user, amount, ILiquidityGauge(gauge), shouldClaimRewards);
            } else if (actions[i] == ActionType.deposit) {
                (
                    address user,
                    uint256 amount,
                    bool addressProcessed,
                    address stablecoinOrStableMaster,
                    address collateral,
                    address poolManager,
                    address sanToken
                ) = abi.decode(datas[i], (address, uint256, bool, address, address, address, address));

                amount = _computeProportion(amount, listTokens, balanceTokens, collateral);
                (amount, sanToken) = _deposit(
                    user,
                    amount,
                    addressProcessed,
                    stablecoinOrStableMaster,
                    collateral,
                    IPoolManager(poolManager),
                    ISanToken(sanToken)
                );

                if (amount > 0) _addToList(listTokens, balanceTokens, sanToken, amount);
            } else if (actions[i] == ActionType.withdraw) {
                (
                    uint256 amount,
                    bool addressProcessed,
                    address stablecoinOrStableMaster,
                    address collateralOrPoolManager,
                    address sanToken
                ) = abi.decode(datas[i], (uint256, bool, address, address, address));

                amount = _computeProportion(amount, listTokens, balanceTokens, sanToken);
                // Reusing the `collateralOrPoolManager` variable to save some variable declarations
                (amount, collateralOrPoolManager) = _withdraw(
                    amount,
                    addressProcessed,
                    stablecoinOrStableMaster,
                    collateralOrPoolManager
                );
                _addToList(listTokens, balanceTokens, collateralOrPoolManager, amount);
            } else if (actions[i] == ActionType.mint) {
                (
                    address user,
                    uint256 amount,
                    uint256 minStableAmount,
                    bool addressProcessed,
                    address stablecoinOrStableMaster,
                    address collateral,
                    address poolManager
                ) = abi.decode(datas[i], (address, uint256, uint256, bool, address, address, address));

                amount = _computeProportion(amount, listTokens, balanceTokens, collateral);
                _mint(
                    user,
                    amount,
                    minStableAmount,
                    addressProcessed,
                    stablecoinOrStableMaster,
                    collateral,
                    IPoolManager(poolManager)
                );
            } else if (actions[i] == ActionType.openPerpetual) {
                (
                    address user,
                    uint256 amount,
                    uint256 amountCommitted,
                    uint256 extremeRateOracle,
                    uint256 minNetMargin,
                    bool addressProcessed,
                    address stablecoinOrPerpetualManager,
                    address collateral
                ) = abi.decode(datas[i], (address, uint256, uint256, uint256, uint256, bool, address, address));

                amount = _computeProportion(amount, listTokens, balanceTokens, collateral);

                _openPerpetual(
                    user,
                    amount,
                    amountCommitted,
                    extremeRateOracle,
                    minNetMargin,
                    addressProcessed,
                    stablecoinOrPerpetualManager,
                    collateral
                );
            } else if (actions[i] == ActionType.addToPerpetual) {
                (
                    uint256 amount,
                    uint256 perpetualID,
                    bool addressProcessed,
                    address stablecoinOrPerpetualManager,
                    address collateral
                ) = abi.decode(datas[i], (uint256, uint256, bool, address, address));

                amount = _computeProportion(amount, listTokens, balanceTokens, collateral);
                _addToPerpetual(amount, perpetualID, addressProcessed, stablecoinOrPerpetualManager, collateral);
            }
        }

        // Once all actions have been performed, the router sends back the unused funds from users
        // If a user sends funds (through a swap) but specifies incorrectly the collateral associated to it, then the mixer will revert
        // When trying to send remaining funds back
        for (uint256 i = 0; i < balanceTokens.length; i++) {
            if (balanceTokens[i] > 0) IERC20(listTokens[i]).safeTransfer(msg.sender, balanceTokens[i]);
        }
    }

    receive() external payable {}

    // ======================== Internal Utility Functions =========================
    // Most internal utility functions have a wrapper built on top of it

    /// @notice Internal version of the `claimRewards` function
    /// Allows to claim rewards for multiple gauges and perpetuals at once
    /// @param gaugeUser Address for which to fetch the rewards from the gauges
    /// @param liquidityGauges Gauges to claim on
    /// @param perpetualIDs Perpetual IDs to claim rewards for
    /// @param addressProcessed Whether `PerpetualManager` list is already accessible in `collateralsOrPerpetualManagers`vor if it should be
    /// retrieved from `stablecoins` and `collateralsOrPerpetualManagers`
    /// @param stablecoins Stablecoin contracts linked to the perpetualsIDs. Array of zero addresses if addressProcessed is true
    /// @param collateralsOrPerpetualManagers Collateral contracts linked to the perpetualsIDs or `perpetualManager` contracts if
    /// `addressProcessed` is true
    /// @dev If the caller wants to send the rewards to another account than `gaugeUser` it first needs to
    /// call `set_rewards_receiver(otherAccount)` on each `liquidityGauge`
    /// @dev The function only takes rewards received by users,
    function _claimRewards(
        address gaugeUser,
        address[] memory liquidityGauges,
        uint256[] memory perpetualIDs,
        bool addressProcessed,
        address[] memory stablecoins,
        address[] memory collateralsOrPerpetualManagers
    ) internal {
        require(
            stablecoins.length == perpetualIDs.length && collateralsOrPerpetualManagers.length == perpetualIDs.length,
            "104"
        );

        for (uint256 i = 0; i < liquidityGauges.length; i++) {
            ILiquidityGauge(liquidityGauges[i]).claim_rewards(gaugeUser);
        }

        for (uint256 i = 0; i < perpetualIDs.length; i++) {
            IPerpetualManagerFrontWithClaim perpManager;
            if (addressProcessed) perpManager = IPerpetualManagerFrontWithClaim(collateralsOrPerpetualManagers[i]);
            else {
                (, Pairs memory pairs) = _getInternalContracts(
                    IERC20(stablecoins[i]),
                    IERC20(collateralsOrPerpetualManagers[i])
                );
                perpManager = pairs.perpetualManager;
            }
            perpManager.getReward(perpetualIDs[i]);
        }
    }

    /// @notice Allows to deposit ANGLE on an existing locker
    /// @param user Address to deposit for
    /// @param amount Amount to deposit
    function _depositOnLocker(address user, uint256 amount) internal {
        VEANGLE.deposit_for(user, amount);
    }

    /// @notice Allows to claim weekly interest distribution and if wanted to transfer it to the `angleRouter` for future use
    /// @param user Address to claim for
    /// @param _feeDistributor Address of the fee distributor to claim to
    /// @dev If funds are transferred to the router, this action cannot be an end in itself, otherwise funds will be lost:
    /// typically we expect people to call for this action before doing a deposit
    /// @dev If `letInContract` (and hence if funds are transferred to the router), you should approve the `angleRouter` to
    /// transfer the token claimed from the `feeDistributor`
    function _claimWeeklyInterest(
        address user,
        IFeeDistributorFront _feeDistributor,
        bool letInContract
    ) internal returns (uint256 amount, IERC20 token) {
        amount = _feeDistributor.claim(user);
        if (letInContract) {
            // Fetching info from the `FeeDistributor` to process correctly the withdrawal
            token = IERC20(_feeDistributor.token());
            token.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            amount = 0;
        }
    }

    /// @notice Internal version of the `gaugeDeposit` function
    /// Allows to deposit tokens into a gauge
    /// @param user Address on behalf of which deposit should be made in the gauge
    /// @param amount Amount to stake
    /// @param gauge LiquidityGauge to stake in
    /// @param shouldClaimRewards Whether to claim or not previously accumulated rewards
    /// @dev You should be cautious on who will receive the rewards (if `shouldClaimRewards` is true)
    /// It can be set on each gauge
    /// @dev In the `mixer`, before calling for this action, user should have made sure to get in the router
    /// the associated token (by like a  `deposit` action)
    /// @dev The function will revert if the gauge has not already been approved by the contract
    function _gaugeDeposit(
        address user,
        uint256 amount,
        ILiquidityGauge gauge,
        bool shouldClaimRewards
    ) internal {
        gauge.deposit(amount, user, shouldClaimRewards);
    }

    /// @notice Internal version of the `mint` functions
    /// Mints stablecoins from the protocol
    /// @param user Address to send the stablecoins to
    /// @param amount Amount of collateral to use for the mint
    /// @param minStableAmount Minimum stablecoin minted for the tx not to revert
    /// @param addressProcessed Whether `msg.sender` provided the contracts address or the tokens one
    /// @param stablecoinOrStableMaster Token associated to a `StableMaster` (if `addressProcessed` is false)
    /// or directly the `StableMaster` contract if `addressProcessed`
    /// @param collateral Collateral to mint from: it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the mint
    /// @param poolManager PoolManager associated to the `collateral` (null if `addressProcessed` is not true)
    /// @dev This function is not designed to be composable with other actions of the router after it's called: like
    /// stablecoins obtained from it cannot be used for other operations: as such the `user` address should not be the router
    /// address
    function _mint(
        address user,
        uint256 amount,
        uint256 minStableAmount,
        bool addressProcessed,
        address stablecoinOrStableMaster,
        address collateral,
        IPoolManager poolManager
    ) internal {
        IStableMasterFront stableMaster;
        (stableMaster, poolManager) = _mintBurnContracts(
            addressProcessed,
            stablecoinOrStableMaster,
            collateral,
            poolManager
        );
        stableMaster.mint(amount, user, poolManager, minStableAmount);
    }

    /// @notice Burns stablecoins from the protocol
    /// @param dest Address who will receive the proceeds
    /// @param amount Amount of collateral to use for the mint
    /// @param minCollatAmount Minimum Collateral minted for the tx not to revert
    /// @param addressProcessed Whether `msg.sender` provided the contracts address or the tokens one
    /// @param stablecoinOrStableMaster Token associated to a `StableMaster` (if `addressProcessed` is false)
    /// or directly the `StableMaster` contract if `addressProcessed`
    /// @param collateral Collateral to mint from: it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the mint
    /// @param poolManager PoolManager associated to the `collateral` (null if `addressProcessed` is not true)
    function _burn(
        address dest,
        uint256 amount,
        uint256 minCollatAmount,
        bool addressProcessed,
        address stablecoinOrStableMaster,
        address collateral,
        IPoolManager poolManager
    ) internal {
        IStableMasterFront stableMaster;
        (stableMaster, poolManager) = _mintBurnContracts(
            addressProcessed,
            stablecoinOrStableMaster,
            collateral,
            poolManager
        );
        stableMaster.burn(amount, msg.sender, dest, poolManager, minCollatAmount);
    }

    /// @notice Internal version of the `deposit` functions
    /// Allows to deposit a collateral within the protocol
    /// @param user Address where to send the resulting sanTokens, if this address is the router address then it means
    /// that the intention is to stake the sanTokens obtained in a subsequent `gaugeDeposit` action
    /// @param amount Amount of collateral to deposit
    /// @param addressProcessed Whether `msg.sender` provided the contracts addresses or the tokens ones
    /// @param stablecoinOrStableMaster Token associated to a `StableMaster` (if `addressProcessed` is false)
    /// or directly the `StableMaster` contract if `addressProcessed`
    /// @param collateral Token to deposit: it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the deposit
    /// @param poolManager PoolManager associated to the `collateral` (null if `addressProcessed` is not true)
    /// @param sanToken SanToken associated to the `collateral` (null if `addressProcessed` is not true)
    /// @dev Contrary to the `mint` action, the `deposit` action can be used in composition with other actions, like
    /// `deposit` and then `stake`
    function _deposit(
        address user,
        uint256 amount,
        bool addressProcessed,
        address stablecoinOrStableMaster,
        address collateral,
        IPoolManager poolManager,
        ISanToken sanToken
    ) internal returns (uint256 addedAmount, address) {
        IStableMasterFront stableMaster;
        if (addressProcessed) {
            stableMaster = IStableMasterFront(stablecoinOrStableMaster);
        } else {
            Pairs memory pairs;
            (stableMaster, pairs) = _getInternalContracts(IERC20(stablecoinOrStableMaster), IERC20(collateral));
            poolManager = pairs.poolManager;
            sanToken = pairs.sanToken;
        }

        if (user == address(this)) {
            // Computing the amount of sanTokens obtained
            addedAmount = sanToken.balanceOf(address(this));
            stableMaster.deposit(amount, address(this), poolManager);
            addedAmount = sanToken.balanceOf(address(this)) - addedAmount;
        } else {
            stableMaster.deposit(amount, user, poolManager);
        }
        return (addedAmount, address(sanToken));
    }

    /// @notice Withdraws sanTokens from the protocol
    /// @param amount Amount of sanTokens to withdraw
    /// @param addressProcessed Whether `msg.sender` provided the contracts addresses or the tokens ones
    /// @param stablecoinOrStableMaster Token associated to a `StableMaster` (if `addressProcessed` is false)
    /// or directly the `StableMaster` contract if `addressProcessed`
    /// @param collateralOrPoolManager Collateral to withdraw (if `addressProcessed` is false) or directly
    /// the `PoolManager` contract if `addressProcessed`
    function _withdraw(
        uint256 amount,
        bool addressProcessed,
        address stablecoinOrStableMaster,
        address collateralOrPoolManager
    ) internal returns (uint256 withdrawnAmount, address) {
        IStableMasterFront stableMaster;
        // Stores the address of the `poolManager`, while `collateralOrPoolManager` is used in the function
        // to store the `collateral` address
        IPoolManager poolManager;
        if (addressProcessed) {
            stableMaster = IStableMasterFront(stablecoinOrStableMaster);
            poolManager = IPoolManager(collateralOrPoolManager);
            collateralOrPoolManager = poolManager.token();
        } else {
            Pairs memory pairs;
            (stableMaster, pairs) = _getInternalContracts(
                IERC20(stablecoinOrStableMaster),
                IERC20(collateralOrPoolManager)
            );
            poolManager = pairs.poolManager;
        }
        // Here reusing the `withdrawnAmount` variable to avoid a stack too deep problem
        withdrawnAmount = IERC20(collateralOrPoolManager).balanceOf(address(this));

        // This call will increase our collateral balance
        stableMaster.withdraw(amount, address(this), address(this), poolManager);

        // We compute the difference between our collateral balance after and before the `withdraw` call
        withdrawnAmount = IERC20(collateralOrPoolManager).balanceOf(address(this)) - withdrawnAmount;

        return (withdrawnAmount, collateralOrPoolManager);
    }

    /// @notice Internal version of the `openPerpetual` function
    /// Opens a perpetual within Angle
    /// @param owner Address to mint perpetual for
    /// @param margin Margin to open the perpetual with
    /// @param amountCommitted Commit amount in the perpetual
    /// @param maxOracleRate Maximum oracle rate required to have a leverage position opened
    /// @param minNetMargin Minimum net margin required to have a leverage position opened
    /// @param addressProcessed Whether msg.sender provided the contracts addresses or the tokens ones
    /// @param stablecoinOrPerpetualManager Token associated to the `StableMaster` (iif `addressProcessed` is false)
    /// or address of the desired `PerpetualManager` (if `addressProcessed` is true)
    /// @param collateral Collateral to mint from (it can be null if `addressProcessed` is true): it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the deposit
    function _openPerpetual(
        address owner,
        uint256 margin,
        uint256 amountCommitted,
        uint256 maxOracleRate,
        uint256 minNetMargin,
        bool addressProcessed,
        address stablecoinOrPerpetualManager,
        address collateral
    ) internal returns (uint256 perpetualID) {
        if (!addressProcessed) {
            (, Pairs memory pairs) = _getInternalContracts(IERC20(stablecoinOrPerpetualManager), IERC20(collateral));
            stablecoinOrPerpetualManager = address(pairs.perpetualManager);
        }

        return
            IPerpetualManagerFrontWithClaim(stablecoinOrPerpetualManager).openPerpetual(
                owner,
                margin,
                amountCommitted,
                maxOracleRate,
                minNetMargin
            );
    }

    /// @notice Internal version of the `addToPerpetual` function
    /// Adds collateral to a perpetual
    /// @param margin Amount of collateral to add
    /// @param perpetualID Perpetual to add collateral to
    /// @param addressProcessed Whether msg.sender provided the contracts addresses or the tokens ones
    /// @param stablecoinOrPerpetualManager Token associated to the `StableMaster` (iif `addressProcessed` is false)
    /// or address of the desired `PerpetualManager` (if `addressProcessed` is true)
    /// @param collateral Collateral to mint from (it can be null if `addressProcessed` is true): it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the deposit
    function _addToPerpetual(
        uint256 margin,
        uint256 perpetualID,
        bool addressProcessed,
        address stablecoinOrPerpetualManager,
        address collateral
    ) internal {
        if (!addressProcessed) {
            (, Pairs memory pairs) = _getInternalContracts(IERC20(stablecoinOrPerpetualManager), IERC20(collateral));
            stablecoinOrPerpetualManager = address(pairs.perpetualManager);
        }
        IPerpetualManagerFrontWithClaim(stablecoinOrPerpetualManager).addToPerpetual(perpetualID, margin);
    }

    // ======================== Internal Utility Functions =========================

    /// @notice Checks if collateral in the list
    /// @param list List of addresses
    /// @param searchFor Address of interest
    /// @return index Place of the address in the list if it is in or current length otherwise
    function _searchList(address[_MAX_TOKENS] memory list, address searchFor) internal pure returns (uint256 index) {
        uint256 i;
        while (i < list.length && list[i] != address(0)) {
            if (list[i] == searchFor) return i;
            i++;
        }
        return i;
    }

    /// @notice Modifies stored balances for a given collateral
    /// @param list List of collateral addresses
    /// @param balances List of balances for the different supported collateral types
    /// @param searchFor Address of the collateral of interest
    /// @param amount Amount to add in the balance for this collateral
    function _addToList(
        address[_MAX_TOKENS] memory list,
        uint256[_MAX_TOKENS] memory balances,
        address searchFor,
        uint256 amount
    ) internal pure {
        uint256 index = _searchList(list, searchFor);
        // add it to the list if non existent and we add tokens
        if (list[index] == address(0)) list[index] = searchFor;
        balances[index] += amount;
    }

    /// @notice Computes the proportion of the collateral leftover balance to use for a given action
    /// @param proportion Ratio to take from balance
    /// @param list Collateral list
    /// @param balances Balances of each collateral asset in the collateral list
    /// @param searchFor Collateral to look for
    /// @return amount Amount to use for the action (based on the proportion given)
    /// @dev To use all the collateral balance available for an action, users should give `proportion` a value of
    /// `BASE_PARAMS`
    function _computeProportion(
        uint256 proportion,
        address[_MAX_TOKENS] memory list,
        uint256[_MAX_TOKENS] memory balances,
        address searchFor
    ) internal pure returns (uint256 amount) {
        uint256 index = _searchList(list, searchFor);

        // Reverts if the index was not found
        require(list[index] != address(0), "33");

        amount = (proportion * balances[index]) / BASE_PARAMS;
        balances[index] -= amount;
    }

    /// @notice Gets Angle contracts associated to a pair (stablecoin, collateral)
    /// @param stablecoin Token associated to a `StableMaster`
    /// @param collateral Collateral to mint/deposit/open perpetual or add collateral from
    /// @dev This function is used to check that the parameters passed by people calling some of the main
    /// router functions are correct
    function _getInternalContracts(IERC20 stablecoin, IERC20 collateral)
        internal
        view
        returns (IStableMasterFront stableMaster, Pairs memory pairs)
    {
        stableMaster = mapStableMasters[stablecoin];
        pairs = mapPoolManagers[stableMaster][collateral];
        // If `stablecoin` is zero then this necessarily means that `stableMaster` here will be 0
        // Similarly, if `collateral` is zero, then this means that `pairs.perpetualManager`, `pairs.poolManager`
        // and `pairs.sanToken` will be zero
        // Last, if any of `pairs.perpetualManager`, `pairs.poolManager` or `pairs.sanToken` is zero, this means
        // that all others should be null from the `addPairs` and `removePairs` functions which keep this invariant
        require(address(stableMaster) != address(0) && address(pairs.poolManager) != address(0), "0");

        return (stableMaster, pairs);
    }

    /// @notice Get contracts for mint and burn actions
    /// @param addressProcessed Whether `msg.sender` provided the contracts address or the tokens one
    /// @param stablecoinOrStableMaster Token associated to a `StableMaster` (if `addressProcessed` is false)
    /// or directly the `StableMaster` contract if `addressProcessed`
    /// @param collateral Collateral to mint from: it can be null if `addressProcessed` is true but in the corresponding
    /// action, the `mixer` needs to get a correct address to compute the amount of tokens to use for the mint
    /// @param poolManager PoolManager associated to the `collateral` (null if `addressProcessed` is not true)
    function _mintBurnContracts(
        bool addressProcessed,
        address stablecoinOrStableMaster,
        address collateral,
        IPoolManager poolManager
    ) internal view returns (IStableMasterFront, IPoolManager) {
        IStableMasterFront stableMaster;
        if (addressProcessed) {
            stableMaster = IStableMasterFront(stablecoinOrStableMaster);
        } else {
            Pairs memory pairs;
            (stableMaster, pairs) = _getInternalContracts(IERC20(stablecoinOrStableMaster), IERC20(collateral));
            poolManager = pairs.poolManager;
        }
        return (stableMaster, poolManager);
    }

    /// @notice Adds new collateral type to specific stablecoin
    /// @param stableMaster Address of the `StableMaster` associated to the stablecoin of interest
    /// @param poolManager Address of the `PoolManager` contract associated to the pair (stablecoin,collateral)
    /// @param liquidityGauge Address of liquidity gauge contract associated to sanToken
    function _addPair(
        IStableMasterFront stableMaster,
        IPoolManager poolManager,
        ILiquidityGauge liquidityGauge
    ) internal {
        // Fetching the associated `sanToken` and `perpetualManager` from the contract
        (IERC20 collateral, ISanToken sanToken, IPerpetualManager perpetualManager, , , , , , ) = IStableMaster(
            address(stableMaster)
        ).collateralMap(poolManager);

        Pairs storage _pairs = mapPoolManagers[stableMaster][collateral];
        // Checking if the pair has not already been initialized: if yes we need to make the function revert
        // otherwise we could end up with still approved `PoolManager` and `PerpetualManager` contracts
        require(address(_pairs.poolManager) == address(0), "114");

        _pairs.poolManager = poolManager;
        _pairs.perpetualManager = IPerpetualManagerFrontWithClaim(address(perpetualManager));
        _pairs.sanToken = sanToken;
        // In the future, it is possible that sanTokens do not have an associated liquidity gauge
        if (address(liquidityGauge) != address(0)) {
            require(address(sanToken) == liquidityGauge.staking_token(), "20");
            _pairs.gauge = liquidityGauge;
            sanToken.approve(address(liquidityGauge), type(uint256).max);
        }
        _changeAllowance(collateral, address(stableMaster), type(uint256).max);
        _changeAllowance(collateral, address(perpetualManager), type(uint256).max);
        emit CollateralToggled(address(stableMaster), address(poolManager), address(liquidityGauge));
    }

    /// @notice Changes allowance of this contract for a given token
    /// @param token Address of the token to change allowance
    /// @param spender Address to change the allowance of
    /// @param amount Amount allowed
    function _changeAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);
        if (currentAllowance < amount) {
            token.safeIncreaseAllowance(spender, amount - currentAllowance);
        } else if (currentAllowance > amount) {
            token.safeDecreaseAllowance(spender, currentAllowance - amount);
        }
    }

    /// @notice Transfers collateral or an arbitrary token which is then swapped on UniswapV3 or on 1Inch
    /// @param inToken Token to swap for the collateral
    /// @param amount Amount of in token to swap for the collateral
    /// @param minAmountOut Minimum amount accepted for the swap to happen
    /// @param swapType Choice on which contracts to swap
    /// @param args Bytes representing either the path to swap your input token to the accepted collateral on Uniswap or payload for 1Inch
    /// @dev The `path` provided is not checked, meaning people could swap for a token A and declare that they've swapped for another token B.
    /// However, the mixer manipulates its token balance only through the addresses registered in `listTokens`, so any subsequent mixer action
    /// trying to transfer funds B will do it through address of token A and revert as A is not actually funded.
    /// In case there is not subsequent action, `mixer` will revert when trying to send back what appears to be remaining tokens A.
    function _transferAndSwap(
        IERC20 inToken,
        uint256 amount,
        uint256 minAmountOut,
        SwapType swapType,
        bytes memory args
    ) internal returns (uint256 amountOut) {
        if (address(inToken) == address(WETH9) && address(this).balance >= amount) {
            WETH9.deposit{ value: amount }(); // wrap only what is needed to pay
        } else {
            inToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        if (swapType == SwapType.UniswapV3) amountOut = _swapOnUniswapV3(inToken, amount, minAmountOut, args);
        else if (swapType == SwapType.oneINCH) amountOut = _swapOn1Inch(inToken, minAmountOut, args);
        else require(false, "3");

        return amountOut;
    }

    /// @notice Allows to swap any token to an accepted collateral via UniswapV3 (if there is a path)
    /// @param inToken Address token used as entrance of the swap
    /// @param amount Amount of in token to swap for the accepted collateral
    /// @param minAmountOut Minimum amount accepted for the swap to happen
    /// @param path Bytes representing the path to swap your input token to the accepted collateral
    function _swapOnUniswapV3(
        IERC20 inToken,
        uint256 amount,
        uint256 minAmountOut,
        bytes memory path
    ) internal returns (uint256 amountOut) {
        // Approve transfer to the `uniswapV3Router` if it is the first time that the token is used
        if (!uniAllowedToken[inToken]) {
            inToken.safeIncreaseAllowance(address(uniswapV3Router), type(uint256).max);
            uniAllowedToken[inToken] = true;
        }
        amountOut = uniswapV3Router.exactInput(
            ExactInputParams(path, address(this), block.timestamp, amount, minAmountOut)
        );
    }

    /// @notice Allows to swap any token to an accepted collateral via 1Inch API
    /// @param minAmountOut Minimum amount accepted for the swap to happen
    /// @param payload Bytes needed for 1Inch API
    function _swapOn1Inch(
        IERC20 inToken,
        uint256 minAmountOut,
        bytes memory payload
    ) internal returns (uint256 amountOut) {
        // Approve transfer to the `oneInch` router if it is the first time the token is used
        if (!oneInchAllowedToken[inToken]) {
            inToken.safeIncreaseAllowance(address(oneInch), type(uint256).max);
            oneInchAllowedToken[inToken] = true;
        }

        //solhint-disable-next-line
        (bool success, bytes memory result) = oneInch.call(payload);
        if (!success) _revertBytes(result);

        amountOut = abi.decode(result, (uint256));
        require(amountOut >= minAmountOut, "15");
    }

    /// @notice Internal function used for error handling
    function _revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length > 0) {
            //solhint-disable-next-line
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert("117");
    }
}
