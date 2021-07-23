// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./StableMasterInternal.sol";

/// @title StableMaster
/// @author Angle Core Team
/// @notice `StableMaster` is the contract handling all the collateral types accepted for a given stablecoin
/// It does all the accounting and is the point of entry in the protocol for stable holders and seekers as well as SLPs
/// @dev This file contains the core functions of the `StableMaster` contract
contract StableMaster is StableMasterInternal, IStableMasterFunctions, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role for `Core` only, used to propagate guardian and governors
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 public constant STABLE = keccak256("STABLE");
    bytes32 public constant SLP = keccak256("SLP");

    // ============================ CONSTRUCTORS AND DEPLOYERS =====================

    /// @notice Creates the access control logic for the governor and guardian addresses
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Guardian address of the protocol
    /// @param _agToken Reference to the `AgToken`, that is the ERC20 token handled by the `StableMaster`
    /// @dev This function is called by the `Core` when a stablecoin is deployed to maintain consistency
    /// across the governor and guardian roles
    /// @dev This function passes the reference of governors and guardian to the corresponding `agToken`
    function deploy(
        address[] memory governorList,
        address guardian,
        address _agToken
    ) external override onlyRole(CORE_ROLE) {
        for (uint256 i = 0; i < governorList.length; i++) {
            grantRole(GOVERNOR_ROLE, governorList[i]);
            grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        grantRole(GUARDIAN_ROLE, guardian);

        agToken = IAgToken(_agToken);
        agToken.deploy(governorList, guardian);
        // Since there is only one address that can be the `AgToken`, and since `AgToken`
        // is not to be admin of any role, we do not define any access control role for it
        // One would have to upgrade the `AgToken` contract to handle a new `AgToken`
    }

    /// @notice Takes into account the gains made while lending and distributes it to SLPs by updating the `sanRate`
    /// @param gain Interests accumulated from lending
    /// @dev This function is called by a `PoolManager` contract having some yield farming strategies associated
    /// @dev To prevent flash loans, the `sanRate` is not directly updated, it is updated at the blocks that follow
    function accumulateInterest(uint256 gain) external override {
        // Searching collateral data
        Collateral storage col = collateralMap[IPoolManager(msg.sender)];
        _contractMapCheck(col);
        // A part of the gain goes to SLP, the rest to the surplus of the protocol
        gain = (gain * col.slpData.interestsForSLPs) / BASE;
        _updateSanRate(gain, col);
    }

    /// @notice Takes into account a loss made by a yield farming strategy
    /// @param loss Loss made by the yield farming strategy
    /// @dev This function is called by a `PoolManager` contract having some yield farming strategies associated
    /// @dev Fees are not accumulated for this function before being distributed: everything is directly used to
    /// update the `sanRate`
    function signalLoss(uint256 loss) external override {
        // Searching collateral data
        IPoolManager poolManager = IPoolManager(msg.sender);
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        uint256 sanMint = col.sanToken.totalSupply();
        if (sanMint != 0) {
            // Updating the `sanRate` by taking into account a loss
            // All the loss is distributed through the `sanRate`
            if (col.sanRate * sanMint > loss * BASE) {
                col.sanRate = col.sanRate - (loss * BASE) / sanMint;
            } else {
                // Normally it should be set to 0, but this would imply that no SLP can enter afterwards
                // we therefore set it to 1 (equivalent to 10**(-18))
                col.sanRate = 1;
                // As it is a critical time, governance pauses SLPs to solve the situation
                _pause(keccak256(abi.encodePacked(SLP, address(poolManager))));
            }
            emit SanRateUpdated(col.sanRate, address(col.token));
        }
    }

    // ============================== HAs ==========================================

    /// @notice Updates the `stocksUsers` that is the collateral to cover from users
    /// corrected by the capital gains or losses of HAs
    /// @param amount Amount to update the stock user with
    /// @dev The parameter is an int, in `PerpetualManager` when calling this function, overflow has been checked for the int
    function updateStocksUsers(int256 amount) external override {
        // Data about the `PerpetualManager` calling the function is fetched using the `contractMap`
        Collateral storage col = collateralMap[contractMap[msg.sender]];
        _contractMapCheck(col);
        col.stocksUsers += amount;

        emit StocksUsersUpdated(address(col.token), col.stocksUsers);
    }

    /// @notice Transforms a HA position into a SLP Position
    /// @param amount The amount to transform
    /// @param user Address to mint sanTokens to
    /// @dev Can only be called by a `PerpetualManager` contract
    /// @dev This is typically useful when a HA wishes to cash out but there is not enough collateral
    /// in reserves
    function convertToSLP(uint256 amount, address user) external override {
        // Data about the `PerpetualManager` calling the function is fetched using the `contractMap`
        Collateral storage col = collateralMap[contractMap[msg.sender]];
        _contractMapCheck(col);
        // we could potentially add
        // _updateSanRate(0, col);
        col.sanToken.mint(user, (amount * BASE) / col.sanRate);
    }

    // ============================ VIEW FUNCTIONS =================================

    /// @notice Transmits information the `PerpetualManager` needs to have to see if new HAs can come in the protocol
    /// @return stocksUsers The collateral brought by users (corrected by capital gains from HAs) that should be covered
    /// if the `maxALock` parameter in the `PerpetualManager` contract is `BASE`
    /// @return The total quantity of agTokens minted
    /// @dev This function will not return a relevant `stocksUsers` if it is not called by a `PerpetualManager`
    function getIssuanceInfo() external view override returns (int256, uint256) {
        int256 stocksUsers = collateralMap[contractMap[msg.sender]].stocksUsers;
        return (stocksUsers, agToken.totalSupply());
    }

    // ============================ VIEW FUNCTION ==================================

    /// @notice Returns the collateral ratio for this stablecoin
    /// @dev The ratio returned is scaled by `BASE` (like all ratios of the protocol)
    function getCollateralRatio() external view override returns (uint256) {
        uint256 mints = agToken.totalSupply();
        if (mints == 0) {
            // If nothing has been minted, the collateral ratio is infinity
            return type(uint256).max;
        }
        uint256 val = 0;
        for (uint256 i = 0; i < managerList.length; i++) {
            Collateral memory collat = collateralMap[managerList[i]];
            // Oracle needs to be called for each collateral to compute the collateral ratio
            val += collat.oracle.readQuote(managerList[i].getTotalAsset());
        }
        return (val * BASE) / mints;
    }

    // ============================== KEEPERS ======================================

    /// @notice Updates all the fees not depending on personal agents inputs via a keeper calling the corresponding
    /// function in the `FeeManager` contract
    /// @param _bonusMalusMint New corrector of user mint fees for this collateral. These fees will correct
    /// the mint fees from users that just depend on the coverage curve by HAs by introducing other dependencies.
    /// In normal times they will be equal to `BASE` meaning fees will just depend on coverage
    /// @param _bonusMalusBurn New corrector of user burn fees, depending on collateral ratio
    /// @param _slippage New global slippage (the SLP fees from withdrawing) factor
    /// @param _slippageFee New global slippage fee (the non distributed accumulated fees) factor
    function setFeeKeeper(
        uint256 _bonusMalusMint,
        uint256 _bonusMalusBurn,
        uint256 _slippage,
        uint256 _slippageFee
    ) external override {
        // Fetching data about the `FeeManager` contract calling this function
        // It is stored in the `contractMap`
        Collateral storage col = collateralMap[contractMap[msg.sender]];
        _contractMapCheck(col);

        col.feeData.bonusMalusMint = _bonusMalusMint;
        col.feeData.bonusMalusBurn = _bonusMalusBurn;
        col.slpData.slippage = _slippage;
        col.slpData.slippageFee = _slippageFee;
    }

    // ================================= GOVERNANCE ================================

    // =============================== Core Functions ==============================

    /// @notice Adds a new governor address
    /// @param governor New governor address
    /// @dev This function propagates changes from `Core` to other contracts
    /// @dev Propagating changes like that allows to maintain the protocol's integrity
    function addGovernor(address governor) external override onlyRole(CORE_ROLE) {
        // Access control for this contract
        grantRole(GOVERNOR_ROLE, governor);
        grantRole(GUARDIAN_ROLE, governor);

        agToken.grantRole(GUARDIAN_ROLE, governor);

        for (uint256 i = 0; i < managerList.length; i++) {
            // The `PoolManager` will echo the changes across all the corresponding contracts
            managerList[i].addGovernor(governor);
        }
    }

    /// @notice Removes a governor address which loses its role
    /// @param governor Governor address to remove
    /// @dev This function propagates changes from `Core` to other contracts
    /// @dev Propagating changes like that allows to maintain the protocol's integrity
    /// @dev It has already been checked in the `Core` that this address could be removed
    /// and that it would not put the protocol in a situation with no governor at all
    function removeGovernor(address governor) external override onlyRole(CORE_ROLE) {
        // Access control for this contract
        revokeRole(GOVERNOR_ROLE, governor);
        revokeRole(GUARDIAN_ROLE, governor);

        agToken.revokeRole(GUARDIAN_ROLE, governor);

        for (uint256 i = 0; i < managerList.length; i++) {
            // The `PoolManager` will echo the changes across all the corresponding contracts
            managerList[i].removeGovernor(governor);
        }
    }

    /// @notice Changes the guardian address
    /// @param newGuardian New guardian address
    /// @param oldGuardian Old guardian address
    /// @dev This function propagates changes from `Core` to other contracts
    /// @dev The zero check for the guardian address has already been performed by the `Core`
    /// contract
    function setGuardian(address newGuardian, address oldGuardian) external override onlyRole(CORE_ROLE) {
        revokeRole(GUARDIAN_ROLE, oldGuardian);
        grantRole(GUARDIAN_ROLE, newGuardian);

        agToken.revokeRole(GUARDIAN_ROLE, oldGuardian);
        agToken.grantRole(GUARDIAN_ROLE, newGuardian);

        for (uint256 i = 0; i < managerList.length; i++) {
            managerList[i].setGuardian(newGuardian, oldGuardian);
        }
    }

    /// @notice Revokes the guardian address
    /// @param oldGuardian Guardian address to revoke
    /// @dev This function propagates changes from `Core` to other contracts
    function revokeGuardian(address oldGuardian) external override onlyRole(CORE_ROLE) {
        revokeRole(GUARDIAN_ROLE, oldGuardian);
        agToken.revokeRole(GUARDIAN_ROLE, oldGuardian);
        for (uint256 i = 0; i < managerList.length; i++) {
            managerList[i].revokeGuardian(oldGuardian);
        }
    }

    // ============================= Governor Functions ============================

    /// @notice Deploys a new collateral by creating the correct references in the corresponding contracts
    /// @param poolManager Contract managing and storing this collateral for this stablecoin
    /// @param perpetualManager Contract managing HA perpetuals for this stablecoin
    /// @param oracle Reference to the oracle that will give the price of the collateral with respect to the stablecoin
    /// @param sanToken Reference to the sanTokens associated to the collateral
    /// @dev All the references in parameters should correspond to contracts that have already been deployed and
    /// initialized with appropriate references
    function deployCollateral(
        IPoolManager poolManager,
        IPerpetualManager perpetualManager,
        IFeeManager feeManager,
        IOracle oracle,
        ISanToken sanToken
    ) external onlyRole(GOVERNOR_ROLE) {
        // Performing zero checks
        require(
            address(poolManager) != address(0) &&
                address(perpetualManager) != address(0) &&
                address(feeManager) != address(0) &&
                address(oracle) != address(0) &&
                address(sanToken) != address(0),
            "zero address"
        );
        // Checking if the collateral has not already been deployed
        Collateral storage col = collateralMap[poolManager];
        require(address(col.token) == address(0), "deployed");
        // Creating the correct references
        col.sanRate = BASE;
        col.token = IERC20(poolManager.token());
        col.sanToken = sanToken;
        col.perpetualManager = perpetualManager;
        col.oracle = oracle;
        col.stocksUsers = 0;
        // Fees need to be initialized for the stablecoin
        // Governance can change them afterwards
        col.feeData.xFeeMint = [0, (3 * BASE) / 10, (6 * BASE) / 10, BASE];
        // Values in the array below should normally be increasing: the lower the `x` the cheaper it should
        // be for stable seekers to come in as a low `x` corresponds to a high demand for volatility and hence
        // to a situation where all the collateral can be covered
        col.feeData.yFeeMint = [(2 * BASE) / 1000, (5 * BASE) / 1000, (25 * BASE) / 1000, (8 * BASE) / 100];
        col.feeData.bonusMalusMint = BASE;
        col.feeData.xFeeBurn = [0, (4 * BASE) / 10, (7 * BASE) / 10, BASE];
        // Values in the array below should normally be decreasing: the higher the `x` the cheaper it should
        // be for stable seekers to go out, as a high `x` corresponds to low demand for volatility and hence
        // to a situation where the protocol has a hard time covering its collateral
        col.feeData.yFeeBurn = [(15 * BASE) / 1000, (5 * BASE) / 1000, (3 * BASE) / 1000, (2 * BASE) / 1000];
        col.feeData.bonusMalusBurn = BASE;
        // SLP data also needs to be initialized, the other values remain 0
        col.slpData.maxSanRateUpdate = (1 * BASE) / 1000;
        col.slpData.feesForSLPs = (5 * BASE) / 10;
        col.slpData.interestsForSLPs = (5 * BASE) / 10;

        // Adding the correct references in the `contractMap` we use in order not to have to pass addresses when
        // calling the `StableMaster` from the `PerpetualManager` contract, or the `FeeManager` contract
        // This is equivalent to granting Access Control roles for these contracts
        contractMap[address(perpetualManager)] = poolManager;
        contractMap[address(feeManager)] = poolManager;
        managerList.push(poolManager);

        // Fetching the governor list and the guardian to initialize the `poolManager` correctly
        address[] memory governorList = core.getGovernorList();
        address guardian = core.guardian();

        // Propagating the deployment
        poolManager.deployCollateral(governorList, guardian, perpetualManager, feeManager);
        emit CollateralDeployed(address(poolManager), address(perpetualManager), address(sanToken), address(oracle));
    }

    /// @notice Removes a collateral from the list of accepted collateral types and pauses all actions associated
    /// to this collateral
    /// @param poolManager Reference to the contract managing this collateral for this stablecoin in the protocol
    /// @param settlementContract Settlement contract that will be used to close everyone's positions and to let
    /// users, SLPs and HAs redeem if not all a portion of their claim
    /// @dev Since this function has the ability to transfer the contract's funds to another contract, it should
    /// only be accessible to the governor
    /// @dev Before calling this function, governance should make sure that all the collateral lent to strategies
    /// has been withdrawn
    function revokeCollateral(IPoolManager poolManager, ICollateralSettler settlementContract)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        // Checking if the `poolManager` given here is well in the list of managers and taking advantage of that to remove
        // the `poolManager` from the list
        uint256 indexMet = 0;
        for (uint256 i = 0; i < managerList.length - 1; i++) {
            if (address(managerList[i]) == address(poolManager)) {
                indexMet = 1;
            }
            if (indexMet == 1) {
                managerList[i] = managerList[i + 1];
            }
        }
        require(indexMet == 1 || managerList[managerList.length - 1] == poolManager, "incorrect poolManager");
        managerList.pop();
        Collateral memory col = collateralMap[poolManager];

        // Deleting the references of the associated contracts: `perpetualManager` and `keeper` in the
        // `contractMap` and `poolManager` from the `collateralMap`
        delete contractMap[poolManager.feeManager()];
        delete contractMap[address(col.perpetualManager)];
        delete collateralMap[poolManager];
        emit CollateralRevoked(address(poolManager));

        // Pausing entry (and exits for HAs)
        col.perpetualManager.pause();
        // No need to pause `SLP` and `STABLE_HOLDERS` as deleting the entry associated to the manager
        // in the `collateralMap` will make everything revert

        // Transferring the whole balance to global settlement
        uint256 balance = col.token.balanceOf(address(poolManager));
        col.token.safeTransferFrom(address(poolManager), address(settlementContract), balance);

        // Settlement works with a fixed oracle value, it needs to be computed here
        // Getting the lowest possible oracle value in order to advantage stable holders
        uint256 oracleValue = col.oracle.readLower(1);
        // Notifying the global settlement contract with the properties of the contract to settle
        // In case of global shutdown, there would be one settlement contract per collateral type
        settlementContract.triggerSettlement(oracleValue, col.sanRate);
    }

    // ============================= Guardian Functions ============================

    /// @notice Pauses an agent's actions within this contract for a given collateral type for this stablecoin
    /// @param agent Bytes representing the agent (`SLP` or `STABLE`) and the collateral type that is going to
    /// be paused. To get the `bytes32` from a string, we use in Solidity a `keccak256` function
    /// @param poolManager Reference to the contract managing this collateral for this stablecoin in the protocol and
    /// for which `agent` needs to be paused
    /// @dev If agent is `STABLE`, it is going to be impossible for users to mint stablecoins using collateral or to burn
    /// their stablecoins
    /// @dev If agent is `SLP`, it is going to be impossible for SLPs to deposit collateral and receive
    /// sanTokens in exchange, or to withdraw collateral from their sanTokens
    function pause(bytes32 agent, IPoolManager poolManager) external onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        _pause(keccak256(abi.encodePacked(agent, address(poolManager))));
    }

    /// @notice Unpauses an agent's action for a given collateral type for this stablecoin
    /// @param agent Agent (`SLP` or `STABLE`) to unpause the action of
    /// @param poolManager Reference to the associated `PoolManager`
    /// @dev Before calling this function, the agent should have been paused for this collateral
    function unpause(bytes32 agent, IPoolManager poolManager) external onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        _unpause(keccak256(abi.encodePacked(agent, address(poolManager))));
    }

    /// @notice Updates the `stocksUsers` for a given collateral to allow or prevent HAs from coming in
    /// @param amount Amount by which increasing or decreasing the `stocksUsers`
    /// @param poolManager Reference to the associated `PoolManager`
    /// @dev This function can be called by governance which is not the case for the other `updateStocksUsers` function
    /// @dev This function can typically be used if there is some surplus that can be put in `stocksUsers`
    /// to allow new HAs to come in
    function updateStocksUsersGov(int256 amount, IPoolManager poolManager) external onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        col.stocksUsers += amount;
        emit StocksUsersUpdated(address(col.token), col.stocksUsers);
    }

    /// @notice Propagates the change of oracle for one collateral to all the contracts which need to have
    /// the correct oracle reference
    /// @param _oracle New oracle contract for the pair collateral/stablecoin
    /// @param poolManager Reference to the `PoolManager` contract associated to the collateral
    function setOracle(IOracle _oracle, IPoolManager poolManager)
        external
        onlyRole(GUARDIAN_ROLE)
        zeroCheck(address(_oracle))
    {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        col.oracle = _oracle;
        emit OracleUpdated(address(poolManager), address(_oracle));
        col.perpetualManager.setOracle(_oracle);
    }

    /// @notice Sets a new `FeeManager` contract and removes the old one which becomes useless
    /// @param newFeeManager New `FeeManager` contract
    /// @param oldFeeManager Old `FeeManager` contract
    /// @param poolManager Reference to the contract managing this collateral for this stablecoin in the protocol
    /// and associated to the `FeeManager` to update
    function setFeeManager(
        address newFeeManager,
        address oldFeeManager,
        IPoolManager poolManager
    ) external onlyRole(GUARDIAN_ROLE) zeroCheck(newFeeManager) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        require(contractMap[oldFeeManager] == poolManager, "invalid manager");
        delete contractMap[oldFeeManager];
        contractMap[newFeeManager] = poolManager;
        poolManager.setFeeManager(IFeeManager(newFeeManager));
    }

    /// @notice Sets the proportion of fees from burn/mint of users going to SLPs
    /// @param _feesForSLPs New proportion of mint/burn fees going to SLPs
    /// @dev The higher this proportion the bigger the APY for SLPs
    function setFeesForSLPs(uint256 _feesForSLPs, IPoolManager poolManager)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_feesForSLPs)
    {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        col.slpData.feesForSLPs = _feesForSLPs;
        emit FeesForSLPsUpdated(address(poolManager), _feesForSLPs);
    }

    /// @notice Sets the maximum `sanRate` update that can happen in a block
    /// @param _maxSanRateUpdate New maximum `sanRate` update
    /// @dev This parameter is here to mitigate front running effects when a large `sanRate` update is coming in
    /// and miners can front-run this update to enter at an advantageous `sanRate`
    function setMaxSanRateUpdate(uint256 _maxSanRateUpdate, IPoolManager poolManager) external onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        col.slpData.maxSanRateUpdate = _maxSanRateUpdate;
        emit MaxSanRateUpdateUpdated(address(poolManager), _maxSanRateUpdate);
    }

    /// @notice Sets the proportion of fees from lending going to SLPs
    /// @param _interestsForSLPs New proportion of interests going to SLPs
    /// @dev The higher this proportion the bigger the APY for SLPs
    function setInterestsForSLPs(uint256 _interestsForSLPs, IPoolManager poolManager)
        external
        onlyRole(GUARDIAN_ROLE)
        onlyCompatibleFees(_interestsForSLPs)
    {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        col.slpData.interestsForSLPs = _interestsForSLPs;
        emit InterestsForSLPsUpdated(address(poolManager), _interestsForSLPs);
    }

    /// @notice Sets the x array (ie thresholds of delta between amount to cover and amount covered by HAs)
    /// and the y array (ie values of fees at thresholds) used to compute mint and burn fees for users
    /// @param poolManager Reference to the `PoolManager` handling the collateral
    /// @param _xFee Thresholds of difference between amount to cover and amount covered by HAs
    /// @param _yFee Values of the fees at thresholds
    /// @param mint Whether mint fees or burn fees should be updated
    /// @dev The evolution of the fees between two thresholds is linear
    /// @dev The length of the two arrays should be the same
    /// @dev The values of `_xFee` should be in ascending order
    function setUserFees(
        IPoolManager poolManager,
        uint256[] memory _xFee,
        uint256[] memory _yFee,
        uint256 mint
    ) external onlyRole(GUARDIAN_ROLE) onlyCompatibleInputArrays(_xFee, _yFee, true) {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        if (mint > 0) {
            col.feeData.xFeeMint = _xFee;
            col.feeData.yFeeMint = _yFee;
            emit ArrayFeeMintUpdated(_xFee, _yFee);
        } else {
            col.feeData.xFeeBurn = _xFee;
            col.feeData.yFeeBurn = _yFee;
            emit ArrayFeeBurnUpdated(_xFee, _yFee);
        }
    }
}
