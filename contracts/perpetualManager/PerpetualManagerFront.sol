// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

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
    /// with respect to the stablecoin. It will be used to compute HA's cash out amounts
    /// @param rewardToken_ Reference to the `rewardtoken` that can be distributed to HAs as they have open positions
    /// @dev The reward token is most likely going to be the ANGLE token
    /// @dev Since this contract is upgradable ,this function is an initialize and not a constructor
    /// @dev Zero checks are only performed on addresses for which no external calls are made, in this case just
    /// the `rewardToken_` is made
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
        _oracle = oracle_;
        rewardToken = rewardToken_;

        // Initializing the fees and parameters of this contract
        // Governance can update these values afterwards
        // This structure of fees was chosen to facilitate testing
        _collatBase = _oracle.getInBase();
        maxALock = (9 * BASE) / 10;
        maxLeverage = 3 * BASE;
        cashOutLeverage = 100 * BASE;
        maintenanceMargin = (3 * BASE) / 1000;
        xHAFeesDeposit = [0, (3 * BASE) / 10, (6 * BASE) / 10, BASE];

        keeperFeesRatio = (5 * BASE) / 10;
        keeperFeesCap = BASE * 100;
        xKeeperFeesCashOut = [BASE / 2, BASE, 2 * BASE];
        yKeeperFeesCashOut = [BASE / 10, (6 * BASE) / 10, BASE / 10];
        // Values in the array below should normally be decreasing: the higher the x the cheaper it should
        // be for HAs to come in
        yHAFeesDeposit = [(3 * BASE) / 100, BASE / 100, (5 * BASE) / 1000, (2 * BASE) / 1000];
        haBonusMalusDeposit = BASE;
        xHAFeesWithdraw = [0, (3 * BASE) / 10, (6 * BASE) / 10, BASE];
        // Values in the array below should normally be increasing: the lower the x the cheaper it should
        // be for HAs to goes out
        yHAFeesWithdraw = [(2 * BASE) / 1000, BASE / 100, (2 * BASE) / 100, (6 * BASE) / 100];
        haBonusMalusWithdraw = BASE;

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

    /// @notice Lets a HA join the protocol
    /// @param owner Address of the future owner of the perpetual
    /// @param amountBrought Amount of collateral brought by the HA
    /// @param amountCommitted Amount of collateral covered by the HA
    /// @return perpetualID The ID of the perpetual opened by this HA
    /// @dev The future owner of the perpetual cannot be the zero address
    /// @dev It is possible to create a perpetual on behalf of someone else
    function createPerpetual(
        address owner,
        uint256 amountBrought,
        uint256 amountCommitted
    ) external whenNotPaused zeroCheck(owner) returns (uint256 perpetualID) {
        require(int256(amountBrought) > 0 && int256(amountCommitted) > 0, "overflow");

        // There could be a reentrancy attack as a call to an external contract is done before state variables
        // updates. Yet in this case, the call involves a transfer from the `msg.sender` to the contract which
        // eliminates the risk
        _token.safeTransferFrom(msg.sender, address(poolManager), amountBrought);

        // Computing the oracle value
        // Only the highest oracle value (between Chainlink and Uniswap) we get is stored in the perpetual
        uint256 rateUp;
        (, rateUp) = _getOraclePrice();
        // Computing the net amount brought by the HAs to store in the perpetual and the fees induced
        (uint256 netBroughtAmount, uint256 fees) = _getNetAmountAndFeesCreation(amountBrought, amountCommitted, rateUp);
        // Checking if the perpetual is not too leveraged
        require((amountCommitted * BASE) <= maxLeverage * netBroughtAmount, "too high leverage");

        // ERC721 logic
        _perpetualIDcount.increment();
        perpetualID = _perpetualIDcount.current();
        _mint(owner, perpetualID);

        // In the logic of the staking contract, the `_updateReward` should be called
        // before the perpetual is created
        _updateReward(perpetualID);

        // Updating the total amount of collateral covered by HAs and creating the perpetual
        totalCAmount += amountCommitted;

        // `netBroughtAmount` is inferior to `broughtAmount` which has been checked for overflow
        // when casting to int in `PoolManager`
        perpetualData[perpetualID] = Perpetual(rateUp, netBroughtAmount, amountCommitted, block.timestamp, fees);

        emit PerpetualUpdate(perpetualID, rateUp, netBroughtAmount, amountCommitted, fees);
    }

    /// @notice Lets a HA cash out a perpetual owned or controlled for the stablecoin/collateral pair associated
    /// to this `PoolManager` contract
    /// @param perpetualID ID of the perpetual to cash out
    /// @param to Address which will receive the proceeds from this perpetual
    /// @dev The HA gets the current amount of her position depending on the entry oracle value
    /// and current oracle value
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    /// @dev If the `PoolManager` does not have enough collateral, the perpetual owner will be converted to a SLP
    function cashOutPerpetual(uint256 perpetualID, address to)
        external
        whenNotPaused
        onlyApprovedOrOwner(msg.sender, perpetualID)
    {
        // Getting the oracle price
        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        // Cashing out the perpetual internally
        // The lowest oracle price between Chainlink and Uniswap is used to compute the perpetual's position at
        // the time of cash out: it is the one that is most at the advantage of the protocol
        (uint256 cashOutAmount, ) = _getCashOutAmount(perpetualID, rateDown);
        _cashOutPerpetual(perpetualID, cashOutAmount);

        // Computing exit fees: they depend on how much is already covered by HAs compared with what's to cover
        // Note that at this point the perpetual has already been cashed out so there is no need to take the change
        // in covered amount occuring when removing this perpetual in the coverage margin
        _secureTransfer(to, _computeFeeHAWithdraw(cashOutAmount, _computeCoverageMargin(0, rateUp)));
    }

    /// @notice Lets a HA increase the `cashOutAmount` in a perpetual she controls for this
    /// stablecoin/collateral pair
    /// @param perpetualID ID of the perpetual to which amount should be added to `cashOutAmount`
    /// @param amount Amount to add to the perpetual's `cashOutAmount`
    /// @dev This decreases the leverage multiple of this perpetual
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    function addToPerpetual(uint256 perpetualID, uint256 amount)
        external
        whenNotPaused
        onlyApprovedOrOwner(msg.sender, perpetualID)
    {
        // Overflow check
        require(int256(amount) > 0, "overflow");
        _token.safeTransferFrom(msg.sender, address(poolManager), amount);

        // Getting the oracle price
        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        // The committed amount does not change, there is no need to update staking variables here
        (uint256 cashOutAmount, ) = _getCashOutAmount(perpetualID, rateDown);

        if (cashOutAmount == 0) {
            // Liquidating the perpetual if it is unhealthy
            _liquidatePerpetual(perpetualID);
        } else {
            // Computing the fees that will be taken on the amount brought
            // The structure of the fees here is the same as when a perpetual is created
            (uint256 netAmount, uint256 fees) = _getNetAmountAndFeesUpdate(amount, rateUp, 1);

            _update(perpetualID, netAmount, false, cashOutAmount, fees, rateUp);
        }
    }

    /// @notice Lets a HA decrease the `cashOutAmount` in a perpetual she controls for this
    /// stablecoin/collateral pair
    /// @param perpetualID ID of the perpetual from which collateral should be removed
    /// @param amount Amount to remove from the perpetual's `cashOutAmount`
    /// @param to Address which will receive the collateral removed from this perpetual
    /// @dev This increases the leverage multiple of this perpetual
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    function removeFromPerpetual(
        uint256 perpetualID,
        uint256 amount,
        address to
    ) external whenNotPaused onlyApprovedOrOwner(msg.sender, perpetualID) {
        // Overflow check
        require(int256(amount) > 0, "overflow");

        // Getting the oracle price
        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        // The committed amount does not change: no need to update staking variables here
        (uint256 cashOutAmount, ) = _getCashOutAmount(perpetualID, rateDown);

        uint256 netAmount = 0;

        if (cashOutAmount <= 0) {
            _liquidatePerpetual(perpetualID);
        } else {
            Perpetual memory perpetual = perpetualData[perpetualID];
            // Checking if money can be withdrawn from the perpetual
            require(
                // The perpetual should not have been created too soon
                (perpetual.creationBlock + secureBlocks <= block.timestamp) &&
                    // The amount to withdraw should not be more important than the perpetual's `cashOutAmount`
                    (amount <= cashOutAmount) &&
                    // Withdrawing collateral should not make the leverage of the perpetual too important
                    ((perpetual.committedAmount * BASE) <= maxLeverage * (cashOutAmount - amount)),
                "invalid conditions"
            );
            // Computing the fees to remove collateral
            // The structure of these fees is the same as when a perpetual is cashed out
            uint256 fees;
            (netAmount, fees) = _getNetAmountAndFeesUpdate(amount, rateUp, 0);

            // Updating the perpetual
            // The perpetual is updated with the amount and not the net amount because of the fees
            _update(perpetualID, amount, true, cashOutAmount, fees, rateUp);
        }

        _secureTransfer(to, netAmount);
    }

    /// @notice Allows an outside caller to liquidate a perpetual if the perpetual position is
    /// under the maintenance margin
    /// @param perpetualID ID of the targeted perpetual
    /// @dev Liquidation will succeed if the `cashOutAmount` of the perpetual is under the maintenance margin,
    /// and it will fail if the perpetual is still healthy
    /// @dev The outside caller (namely a keeper) gets a portion of the fees that were taken to
    /// the HA at perpetual creation
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function liquidatePerpetual(uint256 perpetualID) external whenNotPaused onlyExistingPerpetual(perpetualID) {
        (uint256 rateDown, ) = _getOraclePrice();
        // To compute the `cashOutAmount` in this case, we use the lowest oracle value possible
        (uint256 cashOutAmount, uint256 reachMaintenanceMargin) = _getCashOutAmount(perpetualID, rateDown);
        // Checking if this `cashOutAmount` is such that the perpetual is well to be liquidated
        require(cashOutAmount == 0 || reachMaintenanceMargin == 1, "cashOutAmount not null");

        uint256 fees = perpetualData[perpetualID].fees;
        _liquidatePerpetual(perpetualID);

        // Computing the incentive for the keeper as a function of the fees taken initially to the HA
        // and transfering the rewards to the HA
        _secureTransfer(msg.sender, _computeKeeperHAFees(0, fees));
    }

    /// @notice Allows an outside caller to cash out a perpetual if too much of the collateral from
    /// users is covered by HAs or if the leverage of this perpetual has become too high because of
    /// a too important collateral price decrease
    /// @param perpetualID ID of the targeted perpetual
    /// @dev This function allows to make sure that the protocol will not have too much HAs for a long period of time
    /// or that HAs cannot stay too long with a high leverage in the protocol
    /// @dev The HA that owns the targeted perpetual will get the current value of her perpetual
    /// @dev The call to the function above will revert if the HA cannot be cashed out
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function forceCashOutPerpetual(uint256 perpetualID) external whenNotPaused onlyExistingPerpetual(perpetualID) {
        // Collecting data about the perpetual
        address owner = _owners[perpetualID];

        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        uint256 canBeCashedOut = 0;
        // `ratio` is the ratio between the amount covered by this perpetual and the surplus amount
        // that is covered by HAs although it should not be covered
        uint256 ratio = 0;
        // `amountReturn` is the amount to return to the HA which owned the perpetual
        uint256 amountReturn = 0;
        // First checking if the perpetual should not be liquidated
        (uint256 cashOutAmount, uint256 reachMaintenanceMargin) = _getCashOutAmount(perpetualID, rateDown);
        // `fees` correspond to the fees initially paid by the HA which opened the perpetual
        uint256 fees = perpetualData[perpetualID].fees;
        uint256 committedAmount = perpetualData[perpetualID].committedAmount;
        if (reachMaintenanceMargin == 1 || cashOutAmount == 0) {
            // This results in the perpetual being liquidated and the keeper being paid the same amount of fees as
            // what would have been paid if the perpetual had been liquidated using the `liquidatePerpetualFunction`
            canBeCashedOut = 1;
            // This is a way to ensure that if the perpetual is under the maintenance margin with a non null `cashOutAmount`
            // it will still get liquidated
            cashOutAmount = 0;
        } else {
            // Now checking if too much collateral is not covered by HAs
            (uint256 currentCAmount, uint256 maxCAmount) = _testMaxCAmount(0, rateUp);
            // If too much collateral is covered then the perpetual can be cashed out
            canBeCashedOut = currentCAmount > maxCAmount ? 1 : 0;
            // Quantity used to compute exit fees for the HA
            uint256 margin = 0;
            if (canBeCashedOut > 0) {
                // If too much is covered, computing by how much too much is covered
                // The following quantity is the ratio between the amount covered by the HA
                // (expressed in `BASE` and not in `_collatBase`) divided by the difference between what's covered
                // and what should in place be covered by HAs
                // It is used to compute the amount of fees that will be distributed to the keeper cashing out the perpetual
                // The clean formula is `committedAmount * BASE / _collatBase * BASE / (currentCAmount - maxCAmount)`
                // The reason for this formula is that `committedAmount` is in `_collatBase` and should be converted to base
                // `BASE`
                ratio = (committedAmount * BASE**2) / ((currentCAmount - maxCAmount) * _collatBase);
            } else {
                // Checking if the perpetual can be cashed out because the leverage of the perpetual became too high
                // because of the price decrease
                canBeCashedOut = ((committedAmount * BASE) >= cashOutLeverage * cashOutAmount) ? 1 : 0;
                // The following helps to compute the net amount returned to the perpetual owner
                // The margin should take into account what will be the covered amount after the perpetual is cashed out
                // It is important to pay attention to the base in which the committed amount is expressed
                margin = ((maxCAmount + (committedAmount * BASE) / _collatBase - currentCAmount) * BASE) / maxCAmount;
            }
            // In the case where the perpetual can be cashed out because too much is covered, margin is 0 which means
            // that fee computation considers that everything is already covered
            amountReturn = _computeFeeHAWithdraw(cashOutAmount, margin);
        }
        // The function will revert if the perpetual cannot be cashed out (or liquidated)
        require(canBeCashedOut == 1, "cash out invalid");
        // The case where the perpetual needs to be liquidated is already handled: requirement would be passed.
        // The function to liquidate the perpetual would be called by `_cashOutPerpetual` and the `PoolManager`
        // would receive the fees with a 0 amount to return to the perpetual owner
        _cashOutPerpetual(perpetualID, cashOutAmount);

        // In the case of a perpetual to be liquidated, the `amountReturn` and `ratio` values are equal to 0
        // and this function is useless
        // Giving the perpetual owner the value of her position back
        _secureTransfer(owner, amountReturn);

        // Computing the rewards given to the keeper calling this function
        // and transferring the rewards to the keeper
        _secureTransfer(msg.sender, _computeKeeperHAFees(ratio, fees));
    }

    // =========================== External View Function ==========================

    /// @notice Returns the `cashOutAmount` of the perpetual owned by someone at a given oracle value
    /// @param perpetualID ID of the perpetual
    /// @param rate Oracle value
    /// @return The `cashOutAmount` of the perpetual
    /// @return Whether the position of the perpetual is now too small compared with its initial position
    /// @dev This function is used by the Collateral Settlement contract
    function getCashOutAmount(uint256 perpetualID, uint256 rate) external view override returns (uint256, uint256) {
        return _getCashOutAmount(perpetualID, rate);
    }

    // =========================== Reward Distribution =============================

    /// @notice Allows to check the amount of governance tokens earned by a perpetual
    /// @param perpetualID ID of the perpetual to check
    function earned(uint256 perpetualID) external view returns (uint256) {
        return _earned(perpetualID);
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
        _getReward(perpetualID);
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
        address owner = ownerOf(perpetualID);
        require(to != owner, "approval to current owner");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "caller is not approved");

        _approve(to, perpetualID);
    }

    /// @notice Gets the approved address by a perpetual owner
    /// @param perpetualID ID of the concerned perpetual
    function getApproved(uint256 perpetualID) public view override returns (address) {
        return _getApproved(perpetualID);
    }

    /// @notice Sets approval on all perpetuals owned by the owner to an operator
    /// @param operator Address to approve (or block) on all perpetuals
    /// @param approved Whether the sender wants to approve or block the operator
    function setApprovalForAll(address operator, bool approved) public override {
        require(operator != msg.sender, "approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
    }

    /// @notice Gets if the operator address is approved on all perpetuals by the owner
    /// @param owner Owner of perpetuals
    /// @param operator Address to check if approved
    function isApprovedForAll(address owner, address operator) public view override returns (bool) {
        return _operatorApprovals[owner][operator];
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
    /// @return `true` if the contract implements `interfaceID` and
    ///  `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceId) public pure override(IERC165Upgradeable) returns (bool) {
        return
            interfaceId == type(IAccessControlUpgradeable).interfaceId ||
            interfaceId == type(IERC721Upgradeable).interfaceId ||
            interfaceId == type(IERC165Upgradeable).interfaceId;
    }
}
