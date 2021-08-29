// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./PerpetualManager.sol";

/// @title PerpetualManagerFront
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains the functions of the `PerpetualManager` that can be directly interacted
/// with by external agents. These functions are the ones that need to be called to create, modify or cash out
/// perpetuals
/// @dev `PerpetualManager` naturally handles staking, the code allowing HAs to stake has been inspired from
/// https://github.com/SetProtocol/index-coop-contracts/blob/master/contracts/staking/StakingRewardsV2.sol
/// @dev Perpetuals at Angle protocol are treated as NFTs, this contract handles the logic for that
contract PerpetualManagerFront is PerpetualManager, IPerpetualManagerFront, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    // =============================== Deployer ====================================

    /// @notice Initializes the `PerpetualManager` contract
    /// @param poolManager_ Reference to the `PoolManager` contract handling the collateral associated to the `PerpetualManager`
    /// @param oracle_ Reference to the oracle contract that will give the price of the collateral
    /// with respect to the stablecoin
    /// @param rewardToken_ Reference to the `rewardtoken` that can be distributed to HAs as they have open positions
    /// @dev The reward token is most likely going to be the ANGLE token
    /// @dev Since this contract is upgradeable, this function is an `initialize` and not a `constructor`
    /// @dev Zero checks are only performed on addresses for which no external calls are made, in this case just
    /// the `rewardToken_` is checked
    /// @dev After initializing this contract, all the fee parameters should be initialized by governance using
    /// the setters in this contract
    function initialize(
        IPoolManager poolManager_,
        IOracle oracle_,
        IERC20 rewardToken_
    ) external initializer zeroCheck(address(rewardToken_)) {
        // Initializing contracts
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();

        // Creating references
        poolManager = poolManager_;
        _token = IERC20(poolManager_.token());
        _stableMaster = IStableMaster(poolManager_.stableMaster());
        oracle = oracle_;
        rewardToken = rewardToken_;
        _collatBase = oracle.inBase();

        // Setting up Access Control for this contract
        // There is no need to store the reference to the `PoolManager` address here
        // Once the `POOLMANAGER_ROLE` has been granted, no new addresses can be granted or revoked
        // from this role: a `PerpetualManager` contract can only have one `PoolManager` associated
        _setupRole(POOLMANAGER_ROLE, address(poolManager));
        // `PoolManager` is admin of all the roles. Most of the time, changes are propagated from it
        _setRoleAdmin(GUARDIAN_ROLE, POOLMANAGER_ROLE);
        _setRoleAdmin(POOLMANAGER_ROLE, POOLMANAGER_ROLE);
    }

    // ================================= HAs =======================================

    /// @notice Lets a HA join the protocol and create a perpetual
    /// @param owner Address of the future owner of the perpetual
    /// @param margin Amount of collateral brought by the HA
    /// @param committedAmount Amount of collateral covered by the HA
    /// @param maxOracleRate Maximum oracle value that the HA wants to see stored in the perpetual
    /// @return perpetualID The ID of the perpetual opened by this HA
    /// @dev The future owner of the perpetual cannot be the zero address
    /// @dev It is possible to create a perpetual on behalf of someone else
    /// @dev The `maxOracleRate` parameter serves as a protection against oracle manipulations for HAs opening perpetuals
    function createPerpetual(
        address owner,
        uint256 margin,
        uint256 committedAmount,
        uint256 maxOracleRate
    ) external override whenNotPaused zeroCheck(owner) returns (uint256 perpetualID) {
        // Transaction will revert anyway if `margin` is zero
        require(committedAmount > 0, "zero value");

        // There could be a reentrancy attack as a call to an external contract is done before state variables
        // updates. Yet in this case, the call involves a transfer from the `msg.sender` to the contract which
        // eliminates the risk
        _token.safeTransferFrom(msg.sender, address(poolManager), margin);

        // Computing the oracle value
        // Only the highest oracle value (between Chainlink and Uniswap) we get is stored in the perpetual
        (, uint256 rateUp) = _getOraclePrice();
        // Checking if the oracle rate is not too big: a too big oracle rate could mean for a HA that the price
        // has become too high to make it interesting to create a perpetual
        require(rateUp <= maxOracleRate, "too big oracle rate");

        // Computing the total amount of stablecoins that this perpetual is going to cover
        uint256 totalCoveredAmountUpdate = (committedAmount * rateUp) / _collatBase;
        // Computing the net amount brought by the HAs to store in the perpetual
        uint256 netMargin = _getNetMarginCreation(margin, totalCoveredAmountUpdate, committedAmount);
        // Checking if the perpetual is not too leveraged, even after computing the fees
        require((committedAmount * BASE_PARAMS) <= maxLeverage * netMargin, "too high leverage");

        // ERC721 logic
        _perpetualIDcount.increment();
        perpetualID = _perpetualIDcount.current();
        _mint(owner, perpetualID);

        // In the logic of the staking contract, the `_updateReward` should be called
        // before the perpetual is created
        _updateReward(perpetualID, 0);

        // Updating the total amount of stablecoins covered by HAs and creating the perpetual
        totalCoveredAmount += totalCoveredAmountUpdate;

        perpetualData[perpetualID] = Perpetual(rateUp, block.timestamp, netMargin, committedAmount);
        emit PerpetualCreated(perpetualID, rateUp, netMargin, committedAmount);
    }

    /// @notice Lets a HA cash out a perpetual owned or controlled for the stablecoin/collateral pair associated
    /// to this `PerpetualManager` contract
    /// @param perpetualID ID of the perpetual to cash out
    /// @param to Address which will receive the proceeds from this perpetual
    /// @param minOracleRate Minimum oracle value at which the HA wants to get executed
    /// @dev The HA gets the current amount of her position depending on the entry oracle value
    /// and current oracle value minus some transaction fees computed on the committed amount
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    /// @dev If the `PoolManager` does not have enough collateral, the perpetual owner will be converted to a SLP and
    /// receive sanTokens
    /// @dev The `minOracleRate` serves as a protection for HAs cashing out their perpetuals
    function cashOutPerpetual(
        uint256 perpetualID,
        address to,
        uint256 minOracleRate
    ) external override whenNotPaused onlyApprovedOrOwner(msg.sender, perpetualID) {
        // Loading perpetual data and getting the oracle price
        Perpetual memory perpetual = perpetualData[perpetualID];
        (uint256 rateDown, ) = _getOraclePrice();
        require(rateDown >= minOracleRate, "too small oracle rate");
        // The lowest oracle price between Chainlink and Uniswap is used to compute the perpetual's position at
        // the time of cash out: it is the one that is most at the advantage of the protocol
        (uint256 cashOutAmount, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
        if (liquidated == 0) {
            // You need to wait `lockTime` before being able to withdraw funds from the protocol as a HA
            require(perpetual.entryTimestamp + lockTime <= block.timestamp, "invalid timestamp");
            // Cashing out the perpetual internally
            _cashOutPerpetual(perpetualID, perpetual);
            // Computing exit fees: they depend on how much is already covered by HAs compared with what's to cover
            (uint256 netCashOutAmount, ) = _getNetCashOutAmount(
                cashOutAmount,
                perpetual.committedAmount,
                // The perpetual has already been cashed out when calling this function, so there is no
                // `committedAmount` to add to the `totalCoveredAmount` to get the `currentCoveredAmount`
                _computeCoverageRatio(totalCoveredAmount)
            );
            _secureTransfer(to, netCashOutAmount);
        }
    }

    /// @notice Lets a HA increase the `margin` in a perpetual she controls for this
    /// stablecoin/collateral pair
    /// @param perpetualID ID of the perpetual to which amount should be added to `margin`
    /// @param amount Amount to add to the perpetual's `margin`
    /// @dev This decreases the leverage multiple of this perpetual
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    /// @dev If this perpetual is to be liquidated, the HA is not going to be able to add liquidity to it
    function addToPerpetual(uint256 perpetualID, uint256 amount)
        external
        override
        whenNotPaused
        onlyApprovedOrOwner(msg.sender, perpetualID)
    {
        // Loading perpetual data and getting the oracle price
        Perpetual memory perpetual = perpetualData[perpetualID];
        (uint256 rateDown, ) = _getOraclePrice();
        (, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
        if (liquidated == 0) {
            // Overflow check
            _token.safeTransferFrom(msg.sender, address(poolManager), amount);
            perpetualData[perpetualID].margin += amount;
            emit PerpetualUpdated(perpetualID, perpetual.margin + amount);
        }
    }

    /// @notice Lets a HA decrease the `margin` in a perpetual she controls for this
    /// stablecoin/collateral pair
    /// @param perpetualID ID of the perpetual from which collateral should be removed
    /// @param amount Amount to remove from the perpetual's `margin`
    /// @param to Address which will receive the collateral removed from this perpetual
    /// @dev This increases the leverage multiple of this perpetual
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    function removeFromPerpetual(
        uint256 perpetualID,
        uint256 amount,
        address to
    ) external override whenNotPaused onlyApprovedOrOwner(msg.sender, perpetualID) {
        // Loading perpetual data and getting the oracle price
        Perpetual memory perpetual = perpetualData[perpetualID];
        (uint256 rateDown, ) = _getOraclePrice();

        (uint256 cashOutAmount, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
        if (liquidated == 0) {
            // Checking if money can be withdrawn from the perpetual
            require(
                // The perpetual should not have been created too soon
                (perpetual.entryTimestamp + lockTime <= block.timestamp) &&
                    // The amount to withdraw should not be more important than the perpetual's `cashOutAmount` and `margin`
                    (amount < cashOutAmount) &&
                    (amount < perpetual.margin) &&
                    // Withdrawing should not make the the perpetual pass below its maintenance margin
                    (cashOutAmount - amount) * BASE_PARAMS > perpetual.committedAmount * maintenanceMargin &&
                    // Withdrawing collateral should not make the leverage of the perpetual too important
                    perpetual.committedAmount * BASE_PARAMS <= (perpetual.margin - amount) * maxLeverage,
                "invalid conditions"
            );
            perpetualData[perpetualID].margin -= amount;
            emit PerpetualUpdated(perpetualID, perpetual.margin - amount);

            _secureTransfer(to, amount);
        }
    }

    /// @notice Allows an outside caller to liquidate perpetuals if their position is
    /// under the maintenance margin
    /// @param perpetualIDs ID of the targeted perpetuals
    /// @dev Liquidation of a perpetual will succeed if the `cashOutAmount` of the perpetual is under the maintenance margin,
    /// and nothing will happen if the perpetual is still healthy
    /// @dev The outside caller (namely a keeper) gets a portion of the leftover cash out amount of the perpetual
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function liquidatePerpetuals(uint256[] memory perpetualIDs) external override whenNotPaused {
        // Getting the oracle price
        (uint256 rateDown, ) = _getOraclePrice();
        uint256 liquidationFees;
        for (uint256 i = 0; i < perpetualIDs.length; i++) {
            uint256 perpetualID = perpetualIDs[i];
            require(_exists(perpetualID), "nonexistent perpetual");
            // Loading perpetual data
            Perpetual memory perpetual = perpetualData[perpetualID];
            (uint256 cashOutAmount, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
            if (liquidated == 1) {
                // Computing the incentive for the keeper as a function of the `cashOutAmount` of the perpetual
                // This incentivizes keepers to react fast when the price starts to go below the liquidation
                // margin
                liquidationFees += _computeKeeperLiquidationFees(cashOutAmount);
            }
        }
        _secureTransfer(msg.sender, liquidationFees);
    }

    /// @notice Allows an outside caller to cash out a perpetual if too much of the collateral from
    /// users is covered by HAs
    /// @param perpetualIDs IDs of the targeted perpetuals
    /// @dev This function allows to make sure that the protocol will not have too much HAs for a long period of time
    /// @dev A HA that owns a targeted perpetual will get the current value of her perpetual
    /// @dev The call to the function above will revert if HAs cannot be cashed out
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function forceCashOutPerpetuals(uint256[] memory perpetualIDs) external override whenNotPaused {
        // Getting the oracle price
        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        // Fetching `stocksUsers` to check if perpetuals cover too much collateral
        uint256 stocksUsers = _stableMaster.getStocksUsers();
        uint256 limitCoveredAmount = (stocksUsers * limitHACoverage) / BASE_PARAMS;
        uint256 targetCoveredAmount = (stocksUsers * targetHACoverage) / BASE_PARAMS;

        require(totalCoveredAmount > limitCoveredAmount, "forceCashOut disabled");
        uint256 liquidationFees;
        uint256 cashOutFees;
        for (uint256 i = 0; i < perpetualIDs.length; i++) {
            uint256 perpetualID = perpetualIDs[i];
            address owner = _ownerOf(perpetualID);
            // Loading perpetual data and getting the oracle price
            Perpetual memory perpetual = perpetualData[perpetualID];
            // First checking if the perpetual should not be liquidated
            (uint256 cashOutAmount, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
            if (liquidated == 1) {
                // This results in the perpetual being liquidated and the keeper being paid the same amount of fees as
                // what would have been paid if the perpetual had been liquidated using the `liquidatePerpetualFunction`
                // Computing the incentive for the keeper as a function of the `cashOutAmount` of the perpetual
                // This incentivizes keepers to react fast
                liquidationFees += _computeKeeperLiquidationFees(cashOutAmount);
            } else if (perpetual.entryTimestamp + lockTime <= block.timestamp) {
                // It is impossible to force the cash out a perpetual that was just created: in the other case, this
                // function could be used to do some insider trading and to bypass the `lockTime` limit
                // If too much collateral is covered by HAs, then the perpetual can be cashed out
                _cashOutPerpetual(perpetualID, perpetual);
                uint64 ratioPostCashOut;
                // In this situation, `totalCoveredAmount` is the `currentCoveredAmount`
                if (targetCoveredAmount > totalCoveredAmount) {
                    ratioPostCashOut = uint64((totalCoveredAmount * BASE_PARAMS) / targetCoveredAmount);
                } else {
                    ratioPostCashOut = uint64(BASE_PARAMS);
                }
                // Computing how much the HA will get and the amount of fees paid at cash out
                (uint256 netCashOutAmount, uint256 fees) = _getNetCashOutAmount(
                    cashOutAmount,
                    perpetual.committedAmount,
                    ratioPostCashOut
                );
                cashOutFees += fees;

                _secureTransfer(owner, netCashOutAmount);
            }

            // Checking if at this point enough perpetuals have been cashed out
            if (totalCoveredAmount <= targetCoveredAmount) break;
        }
        uint64 ratio = (targetCoveredAmount == 0)
            ? 0
            : uint64((totalCoveredAmount * BASE_PARAMS) / (2 * targetCoveredAmount));
        // Computing the rewards given to the keeper calling this function
        // and transferring the rewards to the keeper
        // Using a cache value of `cashOutFees` to save some gas
        // The value below is the amount of fees that should go to the keeper forcing the cash out of perpetuals
        // In the linear by part function, if `xKeeperFeesCashOut` is greater than 0.5 (meaning we are not at target yet)
        // then keepers should get almost no fees
        cashOutFees = (cashOutFees * _piecewiseLinear(ratio, xKeeperFeesCashOut, yKeeperFeesCashOut)) / BASE_PARAMS;
        // The amount of fees that can go to keepers is capped by a parameter set by governance
        cashOutFees = cashOutFees < keeperFeesCashOutCap ? cashOutFees : keeperFeesCashOutCap;
        // A malicious attacker could take advantage of this function to take a flash loan, burn agTokens
        // to diminish the stocks users and then force cash out some perpetuals. We also need to check that assuming
        // really small burn transaction fees (of 0.05%), an attacker could make a profit with such flash loan
        // if current coverage is below the target coverage by making such flash loan.
        // The formula for the cost of such flash loan is:
        // `fees * (limitHACoverage - targetHACoverage) * stocksUsers / oracle`
        // In order to avoid doing multiplications after divisions, and to get everything in the correct base, we do:
        uint256 estimatedCost = (5 * (limitHACoverage - targetHACoverage) * stocksUsers * _collatBase) /
            (rateUp * 10000 * BASE_PARAMS);
        cashOutFees = cashOutFees < estimatedCost ? cashOutFees : estimatedCost;
        _secureTransfer(msg.sender, cashOutFees + liquidationFees);
    }

    // =========================== External View Function ==========================

    /// @notice Returns the `cashOutAmount` of the perpetual owned by someone at a given oracle value
    /// @param perpetualID ID of the perpetual
    /// @param rate Oracle value
    /// @return The `cashOutAmount` of the perpetual
    /// @return Whether the position of the perpetual is now too small compared with its initial position
    /// @dev This function is used by the Collateral Settlement contract
    function getCashOutAmount(uint256 perpetualID, uint256 rate) external view override returns (uint256, uint256) {
        Perpetual memory perpetual = perpetualData[perpetualID];
        return _getCashOutAmount(perpetual, rate);
    }

    // =========================== Reward Distribution =============================

    /// @notice Allows to check the amount of governance tokens earned by a perpetual
    /// @param perpetualID ID of the perpetual to check
    function earned(uint256 perpetualID) external view returns (uint256) {
        return _earned(perpetualID, perpetualData[perpetualID].committedAmount * perpetualData[perpetualID].entryRate);
    }

    /// @notice Allows a perpetual owner to withdraw rewards
    /// @param perpetualID ID of the perpetual which accumulated tokens
    /// @dev Only an approved caller can claim the rewards for the perpetual with perpetualID
    function getReward(uint256 perpetualID)
        public
        nonReentrant
        whenNotPaused
        onlyApprovedOrOwner(msg.sender, perpetualID)
    {
        _getReward(perpetualID, perpetualData[perpetualID].committedAmount * perpetualData[perpetualID].entryRate);
    }

    // =============================== ERC721 logic ================================

    /// @notice Gets the balance of an owner
    /// @param owner Address of the owner
    /// @dev Balance here represents the number of perpetuals owned by a HA
    function balanceOf(address owner) public view override returns (uint256) {
        require(owner != address(0), "query for the zero address");
        return _balances[owner];
    }

    /// @notice Gets the owner of the perpetual with ID perpetualID
    /// @param perpetualID ID of the perpetual
    function ownerOf(uint256 perpetualID) public view override returns (address) {
        return _ownerOf(perpetualID);
    }

    /// @notice Approves to an address specified by `to` a perpetual specified by `perpetualID`
    /// @param to Address to approve the perpetual to
    /// @param perpetualID ID of the perpetual
    /// @dev The approved address will have the right to transfer the perpetual, to cash it out
    /// on behalf of the owner, to add or remove collateral in it and to choose the destination
    /// address that will be able to receive the proceeds of the perpetual
    function approve(address to, uint256 perpetualID) public override {
        address owner = _ownerOf(perpetualID);
        require(to != owner, "approval to current owner");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "caller is not approved");

        _approve(to, perpetualID);
    }

    /// @notice Gets the approved address by a perpetual owner
    /// @param perpetualID ID of the concerned perpetual
    function getApproved(uint256 perpetualID) public view override returns (address) {
        require(_exists(perpetualID), "nonexistent perpetual");
        return _getApproved(perpetualID);
    }

    /// @notice Sets approval on all perpetuals owned by the owner to an operator
    /// @param operator Address to approve (or block) on all perpetuals
    /// @param approved Whether the sender wants to approve or block the operator
    function setApprovalForAll(address operator, bool approved) public override {
        require(operator != msg.sender, "approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    /// @notice Gets if the operator address is approved on all perpetuals by the owner
    /// @param owner Owner of perpetuals
    /// @param operator Address to check if approved
    function isApprovedForAll(address owner, address operator) public view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /// @notice Gets if the sender address is approved for the perpetualId
    /// @param perpetualID ID of the perpetual
    function isApprovedOrOwner(address spender, uint256 perpetualID) external view override returns (bool) {
        return _isApprovedOrOwner(spender, perpetualID);
    }

    /// @notice Transfers the `perpetualID` from an address to another
    /// @param from Source address
    /// @param to Destination a address
    /// @param perpetualID ID of the perpetual to transfer
    function transferFrom(
        address from,
        address to,
        uint256 perpetualID
    ) public override onlyApprovedOrOwner(msg.sender, perpetualID) {
        _transfer(from, to, perpetualID);
    }

    /// @notice Safely transfers the `perpetualID` from an address to another without data in it
    /// @param from Source address
    /// @param to Destination a address
    /// @param perpetualID ID of the perpetual to transfer
    function safeTransferFrom(
        address from,
        address to,
        uint256 perpetualID
    ) public override {
        safeTransferFrom(from, to, perpetualID, "");
    }

    /// @notice Safely transfers the `perpetualID` from an address to another with data in the transfer
    /// @param from Source address
    /// @param to Destination a address
    /// @param perpetualID ID of the perpetual to transfer
    function safeTransferFrom(
        address from,
        address to,
        uint256 perpetualID,
        bytes memory _data
    ) public override onlyApprovedOrOwner(msg.sender, perpetualID) {
        _safeTransfer(from, to, perpetualID, _data);
    }

    // =============================== ERC165 logic ================================

    /// @notice Queries if a contract implements an interface
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function uses less than 30,000 gas.
    /// Required by the ERC721 standard, so used to check that the IERC721 is implemented.
    /// @return `true` if the contract implements `interfaceID` and
    ///  `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceId) public pure override(IERC165) returns (bool) {
        return
            interfaceId == type(IPerpetualManagerFront).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
