// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

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

    // ============================ DEPLOYER =======================================

    /// @notice Creates the access control logic for the governor and guardian addresses
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Guardian address of the protocol
    /// @param _agToken Reference to the `AgToken`, that is the ERC20 token handled by the `StableMaster`
    /// @dev This function is called by the `Core` when a stablecoin is deployed to maintain consistency
    /// across the governor and guardian roles
    /// @dev When this function is called by the `Core`, it has already been checked that the `stableMaster`
    /// corresponding to the `agToken` was this `stableMaster`
    function deploy(
        address[] memory governorList,
        address guardian,
        address _agToken
    ) external override onlyRole(CORE_ROLE) {
        for (uint256 i = 0; i < governorList.length; i++) {
            _grantRole(GOVERNOR_ROLE, governorList[i]);
            _grantRole(GUARDIAN_ROLE, governorList[i]);
        }
        _grantRole(GUARDIAN_ROLE, guardian);
        agToken = IAgToken(_agToken);
        // Since there is only one address that can be the `AgToken`, and since `AgToken`
        // is not to be admin of any role, we do not define any access control role for it
    }

    // ============================ STRATEGIES =====================================

    /// @notice Takes into account the gains made while lending and distributes it to SLPs by updating the `sanRate`
    /// @param gain Interests accumulated from lending
    /// @dev This function is called by a `PoolManager` contract having some yield farming strategies associated
    /// @dev To prevent flash loans, the `sanRate` is not directly updated, it is updated at the blocks that follow
    function accumulateInterest(uint256 gain) external override {
        // Searching collateral data
        Collateral storage col = collateralMap[IPoolManager(msg.sender)];
        _contractMapCheck(col);
        // A part of the gain goes to SLPs, the rest to the surplus of the protocol
        _updateSanRate((gain * col.slpData.interestsForSLPs) / BASE_PARAMS, col);
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
            // Updating the `sanRate` and the `lockedInterests` by taking into account a loss
            if (col.sanRate * sanMint + col.slpData.lockedInterests * BASE_TOKENS > loss * BASE_TOKENS) {
                // The loss is first taken from the `lockedInterests`
                uint256 withdrawFromLoss = col.slpData.lockedInterests;

                if (withdrawFromLoss >= loss) {
                    withdrawFromLoss = loss;
                }

                col.slpData.lockedInterests -= withdrawFromLoss;
                col.sanRate -= ((loss - withdrawFromLoss) * BASE_TOKENS) / sanMint;
            } else {
                // Normally it should be set to 0, but this would imply that no SLP can enter afterwards
                // we therefore set it to 1 (equivalent to 10**(-18))
                col.sanRate = 1;
                col.slpData.lockedInterests = 0;
                // As it is a critical time, governance pauses SLPs to solve the situation
                _pause(keccak256(abi.encodePacked(SLP, address(poolManager))));
            }
            emit SanRateUpdated(address(col.token), col.sanRate);
        }
    }

    // ============================== HAs ==========================================

    /// @notice Transforms a HA position into a SLP Position
    /// @param amount The amount to transform
    /// @param user Address to mint sanTokens to
    /// @dev Can only be called by a `PerpetualManager` contract
    /// @dev This is typically useful when a HA wishes to cash out but there is not enough collateral
    /// in reserves
    function convertToSLP(uint256 amount, address user) external override {
        // Data about the `PerpetualManager` calling the function is fetched using the `contractMap`
        IPoolManager poolManager = _contractMap[msg.sender];
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        // If SLPs are paused, in this situation, then this transaction should revert
        // In this extremely rare case, governance should take action and also pause HAs
        _whenNotPaused(SLP, address(poolManager));
        _updateSanRate(0, col);
        col.sanToken.mint(user, (amount * BASE_TOKENS) / col.sanRate);
    }

    /// @notice Sets the proportion of `stocksUsers` available for perpetuals
    /// @param _targetHAHedge New value of the hedge ratio that the protocol wants to arrive to
    /// @dev Can only be called by the `PerpetualManager`
    function setTargetHAHedge(uint64 _targetHAHedge) external override {
        // Data about the `PerpetualManager` calling the function is fetched using the `contractMap`
        IPoolManager poolManager = _contractMap[msg.sender];
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        col.feeData.targetHAHedge = _targetHAHedge;
        // No need to issue an event here, one has already been issued by the corresponding `PerpetualManager`
    }

    // ============================ VIEW FUNCTIONS =================================

    /// @notice Transmits to the `PerpetualManager` the max amount of collateral (in stablecoin value) HAs can hedge
    /// @return _stocksUsers All stablecoins currently assigned to the pool of the caller
    /// @dev This function will not return something relevant if it is not called by a `PerpetualManager`
    function getStocksUsers() external view override returns (uint256 _stocksUsers) {
        _stocksUsers = collateralMap[_contractMap[msg.sender]].stocksUsers;
    }

    /// @notice Returns the collateral ratio for this stablecoin
    /// @dev The ratio returned is scaled by `BASE_PARAMS` since the value is used to
    /// in the `FeeManager` contrat to be compared with the values in `xArrays` expressed in `BASE_PARAMS`
    function getCollateralRatio() external view override returns (uint256) {
        uint256 mints = agToken.totalSupply();
        if (mints == 0) {
            // If nothing has been minted, the collateral ratio is infinity
            return type(uint256).max;
        }
        uint256 val;
        for (uint256 i = 0; i < _managerList.length; i++) {
            // Oracle needs to be called for each collateral to compute the collateral ratio
            val += collateralMap[_managerList[i]].oracle.readQuote(_managerList[i].getTotalAsset());
        }
        return (val * BASE_PARAMS) / mints;
    }

    // ============================== KEEPERS ======================================

    /// @notice Updates all the fees not depending on personal agents inputs via a keeper calling the corresponding
    /// function in the `FeeManager` contract
    /// @param _bonusMalusMint New corrector of user mint fees for this collateral. These fees will correct
    /// the mint fees from users that just depend on the hedge curve by HAs by introducing other dependencies.
    /// In normal times they will be equal to `BASE_PARAMS` meaning fees will just depend on the hedge ratio
    /// @param _bonusMalusBurn New corrector of user burn fees, depending on collateral ratio
    /// @param _slippage New global slippage (the SLP fees from withdrawing) factor
    /// @param _slippageFee New global slippage fee (the non distributed accumulated fees) factor
    function setFeeKeeper(
        uint64 _bonusMalusMint,
        uint64 _bonusMalusBurn,
        uint64 _slippage,
        uint64 _slippageFee
    ) external override {
        // Fetching data about the `FeeManager` contract calling this function
        // It is stored in the `_contractMap`
        Collateral storage col = collateralMap[_contractMap[msg.sender]];
        _contractMapCheck(col);

        col.feeData.bonusMalusMint = _bonusMalusMint;
        col.feeData.bonusMalusBurn = _bonusMalusBurn;
        col.slpData.slippage = _slippage;
        col.slpData.slippageFee = _slippageFee;
        // An event is already emitted in the `FeeManager` contract
    }

    // ============================== AgToken ======================================

    /// @notice Allows the `agToken` contract to update the `stocksUsers` for a given collateral after a burn
    /// with no redeem
    /// @param amount Amount by which `stocksUsers` should decrease
    /// @param poolManager Reference to `PoolManager` for which `stocksUsers` needs to be updated
    /// @dev This function can be called by the `agToken` contract after a burn of agTokens for which no collateral has been
    /// redeemed
    function updateStocksUsers(uint256 amount, address poolManager) external override {
        require(msg.sender == address(agToken), "3");
        Collateral storage col = collateralMap[IPoolManager(poolManager)];
        _contractMapCheck(col);
        require(col.stocksUsers >= amount, "4");
        col.stocksUsers -= amount;
        emit StocksUsersUpdated(address(col.token), col.stocksUsers);
    }

    // ================================= GOVERNANCE ================================

    // =============================== Core Functions ==============================

    /// @notice Changes the `Core` contract
    /// @param newCore New core address
    /// @dev This function can only be called by the `Core` contract
    function setCore(address newCore) external override onlyRole(CORE_ROLE) {
        // Access control for this contract
        _revokeRole(CORE_ROLE, address(_core));
        _grantRole(CORE_ROLE, newCore);
        _core = ICore(newCore);
    }

    /// @notice Adds a new governor address
    /// @param governor New governor address
    /// @dev This function propagates changes from `Core` to other contracts
    /// @dev Propagating changes like that allows to maintain the protocol's integrity
    function addGovernor(address governor) external override onlyRole(CORE_ROLE) {
        // Access control for this contract
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(GUARDIAN_ROLE, governor);

        for (uint256 i = 0; i < _managerList.length; i++) {
            // The `PoolManager` will echo the changes across all the corresponding contracts
            _managerList[i].addGovernor(governor);
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
        _revokeRole(GOVERNOR_ROLE, governor);
        _revokeRole(GUARDIAN_ROLE, governor);

        for (uint256 i = 0; i < _managerList.length; i++) {
            // The `PoolManager` will echo the changes across all the corresponding contracts
            _managerList[i].removeGovernor(governor);
        }
    }

    /// @notice Changes the guardian address
    /// @param newGuardian New guardian address
    /// @param oldGuardian Old guardian address
    /// @dev This function propagates changes from `Core` to other contracts
    /// @dev The zero check for the guardian address has already been performed by the `Core`
    /// contract
    function setGuardian(address newGuardian, address oldGuardian) external override onlyRole(CORE_ROLE) {
        _revokeRole(GUARDIAN_ROLE, oldGuardian);
        _grantRole(GUARDIAN_ROLE, newGuardian);

        for (uint256 i = 0; i < _managerList.length; i++) {
            _managerList[i].setGuardian(newGuardian, oldGuardian);
        }
    }

    /// @notice Revokes the guardian address
    /// @param oldGuardian Guardian address to revoke
    /// @dev This function propagates changes from `Core` to other contracts
    function revokeGuardian(address oldGuardian) external override onlyRole(CORE_ROLE) {
        _revokeRole(GUARDIAN_ROLE, oldGuardian);
        for (uint256 i = 0; i < _managerList.length; i++) {
            _managerList[i].revokeGuardian(oldGuardian);
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
    /// @dev After calling this function, governance should initialize all parameters corresponding to this new collateral
    function deployCollateral(
        IPoolManager poolManager,
        IPerpetualManager perpetualManager,
        IFeeManager feeManager,
        IOracle oracle,
        ISanToken sanToken
    ) external onlyRole(GOVERNOR_ROLE) {
        // If the `sanToken`, `poolManager`, `perpetualManager` and `feeManager` were zero
        // addresses, the following require would fail
        // The only elements that are checked here are those that are defined in the constructors/initializers
        // of the concerned contracts
        require(
            sanToken.stableMaster() == address(this) &&
                sanToken.poolManager() == address(poolManager) &&
                poolManager.stableMaster() == address(this) &&
                perpetualManager.poolManager() == address(poolManager) &&
                // If the `feeManager` is not initialized with the correct `poolManager` then this function
                // will revert when `poolManager.deployCollateral` will be executed
                feeManager.stableMaster() == address(this),
            "9"
        );
        // Checking if the base of the tokens and of the oracle are not similar with one another
        address token = poolManager.token();
        uint256 collatBase = 10**(IERC20Metadata(token).decimals());
        // If the address of the oracle was the zero address, the following would revert
        require(oracle.inBase() == collatBase, "11");
        // Checking if the collateral has not already been deployed
        Collateral storage col = collateralMap[poolManager];
        require(address(col.token) == address(0), "13");

        // Creating the correct references
        col.token = IERC20(token);
        col.sanToken = sanToken;
        col.perpetualManager = perpetualManager;
        col.oracle = oracle;
        // Initializing with the correct values
        col.sanRate = BASE_TOKENS;
        col.collatBase = collatBase;

        // Adding the correct references in the `contractMap` we use in order not to have to pass addresses when
        // calling the `StableMaster` from the `PerpetualManager` contract, or the `FeeManager` contract
        // This is equivalent to granting Access Control roles for these contracts
        _contractMap[address(perpetualManager)] = poolManager;
        _contractMap[address(feeManager)] = poolManager;
        _managerList.push(poolManager);

        // Pausing agents at deployment to leave governance time to set parameters
        // The `PerpetualManager` contract is automatically paused after being initialized, so HAs will not be able to
        // interact with the protocol
        _pause(keccak256(abi.encodePacked(SLP, address(poolManager))));
        _pause(keccak256(abi.encodePacked(STABLE, address(poolManager))));

        // Fetching the governor list and the guardian to initialize the `poolManager` correctly
        address[] memory governorList = _core.governorList();
        address guardian = _core.guardian();

        // Propagating the deployment and passing references to the corresponding contracts
        poolManager.deployCollateral(governorList, guardian, perpetualManager, feeManager, oracle);
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
        uint256 indexMet;
        uint256 managerListLength = _managerList.length;
        require(managerListLength >= 1, "10");
        for (uint256 i = 0; i < managerListLength - 1; i++) {
            if (_managerList[i] == poolManager) {
                indexMet = 1;
                _managerList[i] = _managerList[managerListLength - 1];
                break;
            }
        }
        require(indexMet == 1 || _managerList[managerListLength - 1] == poolManager, "10");
        _managerList.pop();
        Collateral memory col = collateralMap[poolManager];

        // Deleting the references of the associated contracts: `perpetualManager` and `keeper` in the
        // `_contractMap` and `poolManager` from the `collateralMap`
        delete _contractMap[poolManager.feeManager()];
        delete _contractMap[address(col.perpetualManager)];
        delete collateralMap[poolManager];
        emit CollateralRevoked(address(poolManager));

        // Pausing entry (and exits for HAs)
        col.perpetualManager.pause();
        // No need to pause `SLP` and `STABLE_HOLDERS` as deleting the entry associated to the `poolManager`
        // in the `collateralMap` will make everything revert

        // Transferring the whole balance to global settlement
        uint256 balance = col.token.balanceOf(address(poolManager));
        col.token.safeTransferFrom(address(poolManager), address(settlementContract), balance);

        // Settlement works with a fixed oracle value for HAs, it needs to be computed here
        uint256 oracleValue = col.oracle.readLower();
        // Notifying the global settlement contract with the properties of the contract to settle
        // In case of global shutdown, there would be one settlement contract per collateral type
        // Not using the `lockedInterests` to update the value of the sanRate
        settlementContract.triggerSettlement(oracleValue, col.sanRate, col.stocksUsers);
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
    function pause(bytes32 agent, IPoolManager poolManager) external override onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        _pause(keccak256(abi.encodePacked(agent, address(poolManager))));
    }

    /// @notice Unpauses an agent's action for a given collateral type for this stablecoin
    /// @param agent Agent (`SLP` or `STABLE`) to unpause the action of
    /// @param poolManager Reference to the associated `PoolManager`
    /// @dev Before calling this function, the agent should have been paused for this collateral
    function unpause(bytes32 agent, IPoolManager poolManager) external override onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        _unpause(keccak256(abi.encodePacked(agent, address(poolManager))));
    }

    /// @notice Updates the `stocksUsers` for a given pair of collateral
    /// @param amount Amount of `stocksUsers` to transfer from a pool to another
    /// @param poolManagerUp Reference to `PoolManager` for which `stocksUsers` needs to increase
    /// @param poolManagerDown Reference to `PoolManager` for which `stocksUsers` needs to decrease
    /// @dev This function can be called in case where the reserves of the protocol for each collateral do not exactly
    /// match what is stored in the `stocksUsers` because of increases or decreases in collateral prices at times
    /// in which the protocol was not fully hedged by HAs
    /// @dev With this function, governance can allow/prevent more HAs coming in a pool while preventing/allowing HAs
    /// from other pools because the accounting variable of `stocksUsers` does not really match
    function rebalanceStocksUsers(
        uint256 amount,
        IPoolManager poolManagerUp,
        IPoolManager poolManagerDown
    ) external onlyRole(GUARDIAN_ROLE) {
        Collateral storage colUp = collateralMap[poolManagerUp];
        Collateral storage colDown = collateralMap[poolManagerDown];
        // Checking for the `poolManager`
        _contractMapCheck(colUp);
        _contractMapCheck(colDown);
        // The invariant `col.stocksUsers <= col.capOnStableMinted` should remain true even after a
        // governance update
        require(colUp.stocksUsers + amount <= colUp.feeData.capOnStableMinted, "8");
        colDown.stocksUsers -= amount;
        colUp.stocksUsers += amount;
        emit StocksUsersUpdated(address(colUp.token), colUp.stocksUsers);
        emit StocksUsersUpdated(address(colDown.token), colDown.stocksUsers);
    }

    /// @notice Propagates the change of oracle for one collateral to all the contracts which need to have
    /// the correct oracle reference
    /// @param _oracle New oracle contract for the pair collateral/stablecoin
    /// @param poolManager Reference to the `PoolManager` contract associated to the collateral
    function setOracle(IOracle _oracle, IPoolManager poolManager)
        external
        onlyRole(GOVERNOR_ROLE)
        zeroCheck(address(_oracle))
    {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        require(col.oracle != _oracle, "12");
        // The `inBase` of the new oracle should be the same as the `_collatBase` stored for this collateral
        require(col.collatBase == _oracle.inBase(), "11");
        col.oracle = _oracle;
        emit OracleUpdated(address(poolManager), address(_oracle));
        col.perpetualManager.setOracle(_oracle);
    }

    /// @notice Changes the parameters to cap the number of stablecoins you can issue using one
    /// collateral type and the maximum interests you can distribute to SLPs in a sanRate update
    /// in a block
    /// @param _capOnStableMinted New value of the cap
    /// @param _maxInterestsDistributed Maximum amount of interests distributed to SLPs in a block
    /// @param poolManager Reference to the `PoolManager` contract associated to the collateral
    function setCapOnStableAndMaxInterests(
        uint256 _capOnStableMinted,
        uint256 _maxInterestsDistributed,
        IPoolManager poolManager
    ) external override onlyRole(GUARDIAN_ROLE) {
        Collateral storage col = collateralMap[poolManager];
        // Checking for the `poolManager`
        _contractMapCheck(col);
        // The invariant `col.stocksUsers <= col.capOnStableMinted` should remain true even after a
        // governance update
        require(_capOnStableMinted >= col.stocksUsers, "8");
        col.feeData.capOnStableMinted = _capOnStableMinted;
        col.slpData.maxInterestsDistributed = _maxInterestsDistributed;
        emit CapOnStableAndMaxInterestsUpdated(address(poolManager), _capOnStableMinted, _maxInterestsDistributed);
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
        require(_contractMap[oldFeeManager] == poolManager, "10");
        require(newFeeManager != oldFeeManager, "14");
        delete _contractMap[oldFeeManager];
        _contractMap[newFeeManager] = poolManager;
        emit FeeManagerUpdated(address(poolManager), newFeeManager);
        poolManager.setFeeManager(IFeeManager(newFeeManager));
    }

    /// @notice Sets the proportion of fees from burn/mint of users and the proportion
    /// of lending interests going to SLPs
    /// @param _feesForSLPs New proportion of mint/burn fees going to SLPs
    /// @param _interestsForSLPs New proportion of interests from lending going to SLPs
    /// @dev The higher these proportions the bigger the APY for SLPs
    /// @dev These proportions should be inferior to `BASE_PARAMS`
    function setIncentivesForSLPs(
        uint64 _feesForSLPs,
        uint64 _interestsForSLPs,
        IPoolManager poolManager
    ) external override onlyRole(GUARDIAN_ROLE) onlyCompatibleFees(_feesForSLPs) onlyCompatibleFees(_interestsForSLPs) {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        col.slpData.feesForSLPs = _feesForSLPs;
        col.slpData.interestsForSLPs = _interestsForSLPs;
        emit SLPsIncentivesUpdated(address(poolManager), _feesForSLPs, _interestsForSLPs);
    }

    /// @notice Sets the x array (ie ratios between amount hedged by HAs and amount to hedge)
    /// and the y array (ie values of fees at thresholds) used to compute mint and burn fees for users
    /// @param poolManager Reference to the `PoolManager` handling the collateral
    /// @param _xFee Thresholds of hedge ratios
    /// @param _yFee Values of the fees at thresholds
    /// @param _mint Whether mint fees or burn fees should be updated
    /// @dev The evolution of the fees between two thresholds is linear
    /// @dev The length of the two arrays should be the same
    /// @dev The values of `_xFee` should be in ascending order
    /// @dev For mint fees, values in the y-array below should normally be decreasing: the higher the `x` the cheaper
    /// it should be for stable seekers to come in as a high `x` corresponds to a high demand for volatility and hence
    /// to a situation where all the collateral can be hedged
    /// @dev For burn fees, values in the array below should normally be decreasing: the lower the `x` the cheaper it should
    /// be for stable seekers to go out, as a low `x` corresponds to low demand for volatility and hence
    /// to a situation where the protocol has a hard time covering its collateral
    function setUserFees(
        IPoolManager poolManager,
        uint64[] memory _xFee,
        uint64[] memory _yFee,
        uint8 _mint
    ) external override onlyRole(GUARDIAN_ROLE) onlyCompatibleInputArrays(_xFee, _yFee) {
        Collateral storage col = collateralMap[poolManager];
        _contractMapCheck(col);
        if (_mint > 0) {
            col.feeData.xFeeMint = _xFee;
            col.feeData.yFeeMint = _yFee;
        } else {
            col.feeData.xFeeBurn = _xFee;
            col.feeData.yFeeBurn = _yFee;
        }
        emit FeeArrayUpdated(address(poolManager), _xFee, _yFee, _mint);
    }
}
