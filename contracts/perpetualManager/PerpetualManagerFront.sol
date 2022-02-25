// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PerpetualManager.sol";

/// @title PerpetualManagerFront
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains the functions of the `PerpetualManager` that can be directly interacted
/// with by external agents. These functions are the ones that need to be called to open, modify or close
/// perpetuals
/// @dev `PerpetualManager` naturally handles staking, the code allowing HAs to stake has been inspired from
/// https://github.com/SetProtocol/index-coop-contracts/blob/master/contracts/staking/StakingRewardsV2.sol
/// @dev Perpetuals at Angle protocol are treated as NFTs, this contract handles the logic for that
contract PerpetualManagerFront is PerpetualManager, IPerpetualManagerFront {
    using SafeERC20 for IERC20;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    // =============================== Deployer ====================================

    /// @notice Initializes the `PerpetualManager` contract
    /// @param poolManager_ Reference to the `PoolManager` contract handling the collateral associated to the `PerpetualManager`
    /// @param rewardToken_ Reference to the `rewardtoken` that can be distributed to HAs as they have open positions
    /// @dev The reward token is most likely going to be the ANGLE token
    /// @dev Since this contract is upgradeable, this function is an `initialize` and not a `constructor`
    /// @dev Zero checks are only performed on addresses for which no external calls are made, in this case just
    /// the `rewardToken_` is checked
    /// @dev After initializing this contract, all the fee parameters should be initialized by governance using
    /// the setters in this contract
    function initialize(IPoolManager poolManager_, IERC20 rewardToken_)
        external
        initializer
        zeroCheck(address(rewardToken_))
    {
        // Initializing contracts
        __Pausable_init();
        __AccessControl_init();

        // Creating references
        poolManager = poolManager_;
        _token = IERC20(poolManager_.token());
        _stableMaster = IStableMaster(poolManager_.stableMaster());
        rewardToken = rewardToken_;
        _collatBase = 10**(IERC20Metadata(address(_token)).decimals());
        // The references to the `feeManager` and to the `oracle` contracts are to be set when the contract is deployed

        // Setting up Access Control for this contract
        // There is no need to store the reference to the `PoolManager` address here
        // Once the `POOLMANAGER_ROLE` has been granted, no new addresses can be granted or revoked
        // from this role: a `PerpetualManager` contract can only have one `PoolManager` associated
        _setupRole(POOLMANAGER_ROLE, address(poolManager));
        // `PoolManager` is admin of all the roles. Most of the time, changes are propagated from it
        _setRoleAdmin(GUARDIAN_ROLE, POOLMANAGER_ROLE);
        _setRoleAdmin(POOLMANAGER_ROLE, POOLMANAGER_ROLE);
        // Pausing the contract because it is not functional till the collateral has really been deployed by the
        // `StableMaster`
        _pause();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // ================================= HAs =======================================

    /// @notice Lets a HA join the protocol and create a perpetual
    /// @param owner Address of the future owner of the perpetual
    /// @param margin Amount of collateral brought by the HA
    /// @param committedAmount Amount of collateral covered by the HA
    /// @param maxOracleRate Maximum oracle value that the HA wants to see stored in the perpetual
    /// @param minNetMargin Minimum net margin that the HA is willing to see stored in the perpetual
    /// @return perpetualID The ID of the perpetual opened by this HA
    /// @dev The future owner of the perpetual cannot be the zero address
    /// @dev It is possible to open a perpetual on behalf of someone else
    /// @dev The `maxOracleRate` parameter serves as a protection against oracle manipulations for HAs opening perpetuals
    /// @dev `minNetMargin` is a protection against too big variations in the fees for HAs
    function openPerpetual(
        address owner,
        uint256 margin,
        uint256 committedAmount,
        uint256 maxOracleRate,
        uint256 minNetMargin
    ) external override whenNotPaused zeroCheck(owner) returns (uint256 perpetualID) {
        // Transaction will revert anyway if `margin` is zero
        require(committedAmount > 0, "27");

        // There could be a reentrancy attack as a call to an external contract is done before state variables
        // updates. Yet in this case, the call involves a transfer from the `msg.sender` to the contract which
        // eliminates the risk
        _token.safeTransferFrom(msg.sender, address(poolManager), margin);

        // Computing the oracle value
        // Only the highest oracle value (between Chainlink and Uniswap) we get is stored in the perpetual
        (, uint256 rateUp) = _getOraclePrice();
        // Checking if the oracle rate is not too big: a too big oracle rate could mean for a HA that the price
        // has become too high to make it interesting to open a perpetual
        require(rateUp <= maxOracleRate, "28");

        // Computing the total amount of stablecoins that this perpetual is going to hedge for the protocol
        uint256 totalHedgeAmountUpdate = (committedAmount * rateUp) / _collatBase;
        // Computing the net amount brought by the HAs to store in the perpetual
        uint256 netMargin = _getNetMargin(margin, totalHedgeAmountUpdate, committedAmount);
        require(netMargin >= minNetMargin, "29");
        // Checking if the perpetual is not too leveraged, even after computing the fees
        require((committedAmount * BASE_PARAMS) <= maxLeverage * netMargin, "30");

        // ERC721 logic
        _perpetualIDcount.increment();
        perpetualID = _perpetualIDcount.current();

        // In the logic of the staking contract, the `_updateReward` should be called
        // before the perpetual is opened
        _updateReward(perpetualID, 0);

        // Updating the total amount of stablecoins hedged by HAs and creating the perpetual
        totalHedgeAmount += totalHedgeAmountUpdate;

        perpetualData[perpetualID] = Perpetual(rateUp, block.timestamp, netMargin, committedAmount);

        // Following ERC721 logic, the function `_mint(...)` calls `_checkOnERC721Received` and could then be used as
        // a reentrancy vector. Minting should then only be done at the very end after updating all variables.
        _mint(owner, perpetualID);
        emit PerpetualOpened(perpetualID, rateUp, netMargin, committedAmount);
    }

    /// @notice Lets a HA close a perpetual owned or controlled for the stablecoin/collateral pair associated
    /// to this `PerpetualManager` contract
    /// @param perpetualID ID of the perpetual to close
    /// @param to Address which will receive the proceeds from this perpetual
    /// @param minCashOutAmount Minimum net cash out amount that the HA is willing to get for closing the
    /// perpetual
    /// @dev The HA gets the current amount of her position depending on the entry oracle value
    /// and current oracle value minus some transaction fees computed on the committed amount
    /// @dev `msg.sender` should be the owner of `perpetualID` or be approved for this perpetual
    /// @dev If the `PoolManager` does not have enough collateral, the perpetual owner will be converted to a SLP and
    /// receive sanTokens
    /// @dev The `minCashOutAmount` serves as a protection for HAs closing their perpetuals: it protects them both
    /// from fees that would have become too high and from a too big decrease in oracle value
    function closePerpetual(
        uint256 perpetualID,
        address to,
        uint256 minCashOutAmount
    ) external override whenNotPaused onlyApprovedOrOwner(msg.sender, perpetualID) {
        // Loading perpetual data and getting the oracle price
        Perpetual memory perpetual = perpetualData[perpetualID];
        (uint256 rateDown, ) = _getOraclePrice();
        // The lowest oracle price between Chainlink and Uniswap is used to compute the perpetual's position at
        // the time of closing: it is the one that is most at the advantage of the protocol
        (uint256 cashOutAmount, uint256 liquidated) = _checkLiquidation(perpetualID, perpetual, rateDown);
        if (liquidated == 0) {
            // You need to wait `lockTime` before being able to withdraw funds from the protocol as a HA
            require(perpetual.entryTimestamp + lockTime <= block.timestamp, "31");
            // Cashing out the perpetual internally
            _closePerpetual(perpetualID, perpetual);
            // Computing exit fees: they depend on how much is already hedgeded by HAs compared with what's to hedge
            (uint256 netCashOutAmount, ) = _getNetCashOutAmount(
                cashOutAmount,
                perpetual.committedAmount,
                // The perpetual has already been cashed out when calling this function, so there is no
                // `committedAmount` to add to the `totalHedgeAmount` to get the `currentHedgeAmount`
                _computeHedgeRatio(totalHedgeAmount)
            );
            require(netCashOutAmount >= minCashOutAmount, "32");
            emit PerpetualClosed(perpetualID, netCashOutAmount);
            _secureTransfer(to, netCashOutAmount);
        }
    }

    /// @notice Lets a HA increase the `margin` in a perpetual she controls for this
    /// stablecoin/collateral pair
    /// @param perpetualID ID of the perpetual to which amount should be added to `margin`
    /// @param amount Amount to add to the perpetual's `margin`
    /// @dev This decreases the leverage multiple of this perpetual
    /// @dev If this perpetual is to be liquidated, the HA is not going to be able to add liquidity to it
    /// @dev Since this function can be used to add liquidity to a perpetual, there is no need to restrict
    /// it to the owner of the perpetual
    /// @dev Calling this function on a non-existing perpetual makes it revert
    function addToPerpetual(uint256 perpetualID, uint256 amount) external override whenNotPaused {
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
                // The perpetual should not have been opened too soon
                (perpetual.entryTimestamp + lockTime <= block.timestamp) &&
                    // The amount to withdraw should not be more important than the perpetual's `cashOutAmount` and `margin`
                    (amount < cashOutAmount) &&
                    (amount < perpetual.margin) &&
                    // Withdrawing collateral should not make the leverage of the perpetual too important
                    // Checking both on `cashOutAmount` and `perpetual.margin` (as we can have either
                    // `cashOutAmount >= perpetual.margin` or `cashOutAmount<perpetual.margin`)
                    // No checks are done on `maintenanceMargin`, as conditions on `maxLeverage` are more restrictive
                    perpetual.committedAmount * BASE_PARAMS <= (cashOutAmount - amount) * maxLeverage &&
                    perpetual.committedAmount * BASE_PARAMS <= (perpetual.margin - amount) * maxLeverage,
                "33"
            );
            perpetualData[perpetualID].margin -= amount;
            emit PerpetualUpdated(perpetualID, perpetual.margin - amount);

            _secureTransfer(to, amount);
        }
    }

    /// @notice Allows an outside caller to liquidate perpetuals if their margin ratio is
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
            if (_exists(perpetualID)) {
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
        }
        emit KeeperTransferred(msg.sender, liquidationFees);
        _secureTransfer(msg.sender, liquidationFees);
    }

    /// @notice Allows an outside caller to close perpetuals if too much of the collateral from
    /// users is hedged by HAs
    /// @param perpetualIDs IDs of the targeted perpetuals
    /// @dev This function allows to make sure that the protocol will not have too much HAs for a long period of time
    /// @dev A HA that owns a targeted perpetual will get the current value of her perpetual
    /// @dev The call to the function above will revert if HAs cannot be cashed out
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    function forceClosePerpetuals(uint256[] memory perpetualIDs) external override whenNotPaused {
        // Getting the oracle prices
        // `rateUp` is used to compute the cost of manipulation of the covered amounts
        (uint256 rateDown, uint256 rateUp) = _getOraclePrice();

        // Fetching `stocksUsers` to check if perpetuals cover too much collateral
        uint256 stocksUsers = _stableMaster.getStocksUsers();
        uint256 targetHedgeAmount = (stocksUsers * targetHAHedge) / BASE_PARAMS;

        // `totalHedgeAmount` should be greater than the limit hedge amount
        require(totalHedgeAmount > (stocksUsers * limitHAHedge) / BASE_PARAMS, "34");
        uint256 liquidationFees;
        uint256 cashOutFees;

        // Array of pairs `(owner, netCashOutAmount)`
        Pairs[] memory outputPairs = new Pairs[](perpetualIDs.length);

        for (uint256 i = 0; i < perpetualIDs.length; i++) {
            uint256 perpetualID = perpetualIDs[i];
            address owner = _owners[perpetualID];
            if (owner != address(0)) {
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
                    // It is impossible to force the closing a perpetual that was just created: in the other case, this
                    // function could be used to do some insider trading and to bypass the `lockTime` limit
                    // If too much collateral is hedged by HAs, then the perpetual can be cashed out
                    _closePerpetual(perpetualID, perpetual);
                    uint64 ratioPostCashOut;
                    // In this situation, `totalHedgeAmount` is the `currentHedgeAmount`
                    if (targetHedgeAmount > totalHedgeAmount) {
                        ratioPostCashOut = uint64((totalHedgeAmount * BASE_PARAMS) / targetHedgeAmount);
                    } else {
                        ratioPostCashOut = uint64(BASE_PARAMS);
                    }
                    // Computing how much the HA will get and the amount of fees paid at closing
                    (uint256 netCashOutAmount, uint256 fees) = _getNetCashOutAmount(
                        cashOutAmount,
                        perpetual.committedAmount,
                        ratioPostCashOut
                    );
                    cashOutFees += fees;
                    // Storing the owners of perpetuals that were forced cash out in a memory array to avoid
                    // reentrancy attacks
                    outputPairs[i] = Pairs(owner, netCashOutAmount);
                }

                // Checking if at this point enough perpetuals have been cashed out
                if (totalHedgeAmount <= targetHedgeAmount) break;
            }
        }

        uint64 ratio = (targetHedgeAmount == 0)
            ? 0
            : uint64((totalHedgeAmount * BASE_PARAMS) / (2 * targetHedgeAmount));
        // Computing the rewards given to the keeper calling this function
        // and transferring the rewards to the keeper
        // Using a cache value of `cashOutFees` to save some gas
        // The value below is the amount of fees that should go to the keeper forcing the closing of perpetuals
        // In the linear by part function, if `xKeeperFeesClosing` is greater than 0.5 (meaning we are not at target yet)
        // then keepers should get almost no fees
        cashOutFees = (cashOutFees * _piecewiseLinear(ratio, xKeeperFeesClosing, yKeeperFeesClosing)) / BASE_PARAMS;
        // The amount of fees that can go to keepers is capped by a parameter set by governance
        cashOutFees = cashOutFees < keeperFeesClosingCap ? cashOutFees : keeperFeesClosingCap;
        // A malicious attacker could take advantage of this function to take a flash loan, burn agTokens
        // to diminish the stocks users and then force close some perpetuals. We also need to check that assuming
        // really small burn transaction fees (of 0.05%), an attacker could make a profit with such flash loan
        // if current hedge is below the target hedge by making such flash loan.
        // The formula for the cost of such flash loan is:
        // `fees * (limitHAHedge - targetHAHedge) * stocksUsers / oracle`
        // In order to avoid doing multiplications after divisions, and to get everything in the correct base, we do:
        uint256 estimatedCost = (5 * (limitHAHedge - targetHAHedge) * stocksUsers * _collatBase) /
            (rateUp * 10000 * BASE_PARAMS);
        cashOutFees = cashOutFees < estimatedCost ? cashOutFees : estimatedCost;

        emit PerpetualsForceClosed(perpetualIDs, outputPairs, msg.sender, cashOutFees + liquidationFees);

        // Processing transfers after all calculations have been performed
        for (uint256 j = 0; j < perpetualIDs.length; j++) {
            if (outputPairs[j].netCashOutAmount > 0) {
                _secureTransfer(outputPairs[j].owner, outputPairs[j].netCashOutAmount);
            }
        }
        _secureTransfer(msg.sender, cashOutFees + liquidationFees);
    }

    // =========================== External View Function ==========================

    /// @notice Returns the `cashOutAmount` of the perpetual owned by someone at a given oracle value
    /// @param perpetualID ID of the perpetual
    /// @param rate Oracle value
    /// @return The `cashOutAmount` of the perpetual
    /// @return Whether the position of the perpetual is now too small compared with its initial position and should hence
    /// be liquidated
    /// @dev This function is used by the Collateral Settlement contract
    function getCashOutAmount(uint256 perpetualID, uint256 rate) external view override returns (uint256, uint256) {
        Perpetual memory perpetual = perpetualData[perpetualID];
        return _getCashOutAmount(perpetual, rate);
    }

    // =========================== Reward Distribution =============================

    /// @notice Allows to check the amount of reward tokens earned by a perpetual
    /// @param perpetualID ID of the perpetual to check
    function earned(uint256 perpetualID) external view returns (uint256) {
        return _earned(perpetualID, perpetualData[perpetualID].committedAmount * perpetualData[perpetualID].entryRate);
    }

    /// @notice Allows a perpetual owner to withdraw rewards
    /// @param perpetualID ID of the perpetual which accumulated tokens
    function getReward(uint256 perpetualID) external whenNotPaused {
        require(_exists(perpetualID), "2");
        _getReward(perpetualID, perpetualData[perpetualID].committedAmount * perpetualData[perpetualID].entryRate);
    }

    // =============================== ERC721 logic ================================

    /// @notice Gets the name of the NFT collection implemented by this contract
    function name() external pure override returns (string memory) {
        return "AnglePerp";
    }

    /// @notice Gets the symbol of the NFT collection implemented by this contract
    function symbol() external pure override returns (string memory) {
        return "AnglePerp";
    }

    /// @notice Gets the URI containing metadata
    /// @param perpetualID ID of the perpetual
    function tokenURI(uint256 perpetualID) external view override returns (string memory) {
        require(_exists(perpetualID), "2");
        // There is no perpetual with `perpetualID` equal to 0, so the following variable is
        // always greater than zero
        uint256 temp = perpetualID;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (perpetualID != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(perpetualID % 10)));
            perpetualID /= 10;
        }
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, string(buffer))) : "";
    }

    /// @notice Gets the balance of an owner
    /// @param owner Address of the owner
    /// @dev Balance here represents the number of perpetuals owned by a HA
    function balanceOf(address owner) external view override returns (uint256) {
        require(owner != address(0), "0");
        return _balances[owner];
    }

    /// @notice Gets the owner of the perpetual with ID perpetualID
    /// @param perpetualID ID of the perpetual
    function ownerOf(uint256 perpetualID) external view override returns (address) {
        return _ownerOf(perpetualID);
    }

    /// @notice Approves to an address specified by `to` a perpetual specified by `perpetualID`
    /// @param to Address to approve the perpetual to
    /// @param perpetualID ID of the perpetual
    /// @dev The approved address will have the right to transfer the perpetual, to cash it out
    /// on behalf of the owner, to add or remove collateral in it and to choose the destination
    /// address that will be able to receive the proceeds of the perpetual
    function approve(address to, uint256 perpetualID) external override {
        address owner = _ownerOf(perpetualID);
        require(to != owner, "35");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "21");

        _approve(to, perpetualID);
    }

    /// @notice Gets the approved address by a perpetual owner
    /// @param perpetualID ID of the concerned perpetual
    function getApproved(uint256 perpetualID) external view override returns (address) {
        require(_exists(perpetualID), "2");
        return _getApproved(perpetualID);
    }

    /// @notice Sets approval on all perpetuals owned by the owner to an operator
    /// @param operator Address to approve (or block) on all perpetuals
    /// @param approved Whether the sender wants to approve or block the operator
    function setApprovalForAll(address operator, bool approved) external override {
        require(operator != msg.sender, "36");
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
    ) external override onlyApprovedOrOwner(msg.sender, perpetualID) {
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
    ) external override {
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
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return
            interfaceId == type(IPerpetualManagerFront).interfaceId ||
            interfaceId == type(IPerpetualManagerFunctions).interfaceId ||
            interfaceId == type(IStakingRewards).interfaceId ||
            interfaceId == type(IStakingRewardsFunctions).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
