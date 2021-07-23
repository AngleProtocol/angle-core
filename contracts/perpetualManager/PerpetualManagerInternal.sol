// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./PerpetualManagerStorage.sol";

/// @title PerpetualManagerInternal
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains all the internal functions of the `PerpetualManager` contract
contract PerpetualManagerInternal is PerpetualManagerStorage {
    using Address for address;
    using SafeERC20 for IERC20;

    // ========================= HA Perpetuals Functions ===========================

    /// @notice Liquidates a perpetual
    /// @param perpetualID ID of the perpetual being liquidated
    /// @dev This function is only called once required checks have been done
    function _liquidatePerpetual(uint256 perpetualID) internal {
        Perpetual memory perpetual = perpetualData[perpetualID];
        // Handling the staking logic
        // Reward should always be updated before the `totalCAmount`
        // Rewards are distributed to the perpetual which is liquidated
        _getReward(perpetualID);
        delete perpetualRewardPerTokenPaid[perpetualID];

        // Updating `totalCAmount` to represent the fact that less collateral is now insured
        totalCAmount -= perpetual.committedAmount;

        // Burning the perpetual
        _burn(perpetualID);

        // Transfering the amount to stocks users to represent the fact that this amount now
        // belongs to the protocol and should be insured
        // The int conversion cannot normally overflow here as the `perpetual.cashOutAmount` can only come
        // from the `_update` or `createPerpetual` functions where the condition is checked
        _stableMaster.updateStocksUsers(int256(perpetual.cashOutAmount));
    }

    /// @notice Cashes out a perpetual
    /// @param perpetualID ID of the perpetual
    /// @param cashOutAmount The current cash out amount of the perpetual, that is the amount that the perpetual
    /// owner is entitled to get from the contract (without taking into account the fees)
    /// @dev Every time this function is called the `cashOutAmount` has previously been computed
    function _cashOutPerpetual(uint256 perpetualID, uint256 cashOutAmount) internal {
        Perpetual memory perpetual = perpetualData[perpetualID];
        if (cashOutAmount == 0) {
            // If the perpetual needs to be liquidated, logic is changed
            _liquidatePerpetual(perpetualID);
        } else {
            // Checking if the perpetual can be cashed out yet
            require(perpetual.creationBlock + secureBlocks <= block.timestamp, "invalid timestamp");
            // Checking for overflows because some quantities will be converted to int
            // `perpetual.cashOutAmount` has been checked for overflow when it got updated in `_update`
            // and at perpetual creation
            require(int256(cashOutAmount) >= 0, "overflow");

            // This is as a staking withdraw: we call `_updateRewards` before other updates are made
            _getReward(perpetualID);
            delete perpetualRewardPerTokenPaid[perpetualID];

            // Updating `totalCAmount` to represent the fact that less money is insured
            totalCAmount -= perpetual.committedAmount;

            _burn(perpetualID);

            // Updating `stocksUsers` before the cash out
            _stableMaster.updateStocksUsers(int256(perpetual.cashOutAmount) - int256(cashOutAmount));
        }
    }

    /// @notice Updates the perpetual associated to perpetualID
    /// @param perpetualID ID of the perpetual
    /// @param amount Amount of the transaction
    /// @param withdraw Whether the owner or the approved person wishes to withdraw or add collateral
    /// @param curCashOutAmount Current `cashOutAmount` of the perpetual
    /// @param fees Fees to add to the liquidation reward
    /// @param rate Rate of the oracle
    /// @dev This function is typically called when a HA adds or removes collateral from an owned perpetual
    /// @dev The rate fed to this function will most of the time be a high value (the highest between Uniswap and Chainlink)
    /// because it is what is most at the protocol's advantage
    /// @dev The `cashOutAmount` fed to this function will have been computed using a low oracle value
    function _update(
        uint256 perpetualID,
        uint256 amount,
        bool withdraw,
        uint256 curCashOutAmount,
        uint256 fees,
        uint256 rate
    ) internal {
        Perpetual storage perpetual = perpetualData[perpetualID];
        // Computing the perpetual's new cash out amount, it is simply the current's `cashOutAmount` updated by the amount
        uint256 newCashOutAmount;
        if (withdraw) {
            // It has been checked in `removeFromPerpetual` that amount was not bigger than `cashOutAmount`
            newCashOutAmount = curCashOutAmount - amount;
        } else {
            newCashOutAmount = curCashOutAmount + amount;
        }
        // Checking the require before any state update to save gas
        // Updating the collateral from users to cover by the capital gain or loss made by HA:
        // overflow checked need to be performed
        // The `perpetual.cashOutAmount` by HAs is always checked for overflows when casting to int
        // whenever it is updated (it is the `newCashOutAmount` here), no need to double check with a
        // `require(int256(perpetual.cashOutAmount) >= 0)`
        // For one of this to overflow, some very specific conditions on `BASE` are required
        require((int256(newCashOutAmount) >= 0) && (int256(curCashOutAmount) >= 0), "overflow");

        int256 oldCashOutAmount = int256(perpetual.cashOutAmount);

        // Updating the parameters of the perpetual
        perpetual.initialRate = rate;
        // The new cash out amount by the perpetual is now the `cashOutAmount` of the perpetual
        perpetual.cashOutAmount = newCashOutAmount;
        perpetual.creationBlock = block.timestamp;
        perpetual.fees += fees;
        emit PerpetualUpdate(perpetualID, rate, newCashOutAmount, perpetual.committedAmount, perpetual.fees);

        _stableMaster.updateStocksUsers(oldCashOutAmount - int256(curCashOutAmount));
    }

    /// @notice Allows to transfer collateral to an address while handling the case where there are
    /// not enough reserves
    /// @param owner Address of the receiver
    /// @param amount The amount of collateral sent
    /// @dev If there is not enough collateral in balance (this can happen when money has been lent),
    /// then the owner is reimbursed by receiving the delta in sanTokens at the correct value
    function _secureTransfer(address owner, uint256 amount) internal {
        if (amount > 0) {
            uint256 curBalance = poolManager.getBalance();
            if (curBalance >= amount) {
                // Case where there is enough in reserves to reimburse the person
                _token.safeTransferFrom(address(poolManager), owner, amount);
            } else {
                // When there is not enough to reimburse the entire amount, the protocol will reimburse
                // what it can using its reserves and the rest will be paid in sanTokens at the current
                // exchange rate
                uint256 amountLeft = amount - curBalance;
                _token.safeTransferFrom(address(poolManager), owner, curBalance);
                _stableMaster.convertToSLP(amountLeft, owner);
            }
        }
    }

    // ============================= Internal view =================================

    /// @notice Computes the amount that is covered by HAs and the amount that they are allowed to cover
    /// @param amount Amount to add to the current total amount committed
    /// @param rate Value of the oracle, used to compute the maximum amount to cover
    /// @return newCoveredAmount Amount of collateral insured by HAs if `amount` more collateral is covered
    /// @return maxCoveredAmount Maximum amount of collateral that can be insured
    function _testMaxCAmount(uint256 amount, uint256 rate)
        internal
        view
        returns (uint256 newCoveredAmount, uint256 maxCoveredAmount)
    {
        // Fetching info from the `StableMaster`
        int256 signedStocksUsers;
        uint256 agTokensMinted;
        (signedStocksUsers, agTokensMinted) = _stableMaster.getIssuanceInfo();

        // Case where there are too many HAs and no new HAs can come in
        if (signedStocksUsers <= 0) return (1, 0);

        // Everything needs to be set in the same base
        newCoveredAmount = ((totalCAmount + amount) * BASE) / _collatBase;

        uint256 stocksUsers = (uint256(signedStocksUsers) * BASE) / _collatBase;
        // We multiply by `BASE` because rate is in `BASE`
        uint256 stablecoinsInCol = (agTokensMinted * BASE) / rate;

        // To compute the maximum covered amount, we take the minimum between the minted assets and `stocksUsers`
        // To gain precision, instead of using the formula:
        // `maxCoveredAmount = (stocksUsers * maxTotalCoveredAmount) / BASE;`, we do:
        if (stablecoinsInCol >= stocksUsers)
            maxCoveredAmount = (uint256(signedStocksUsers) * maxALock) / _collatBase;
            // Same here, instead of using:
            // `maxCoveredAmount = (stablecoinsInCol * maxTotalCoveredAmount) / BASE;`, we do:
        else maxCoveredAmount = (agTokensMinted * maxALock) / rate;
        // Both of the returned amounts are in `BASE`
    }

    /// @notice Gets the current `cashOutAmount` of a perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @param rate Value of the oracle
    /// @return newCashOutAmount New `cashOutAmount` of the perpetual
    /// @return reachMaintenanceMargin Whether the position of the perpetual is now too small
    /// compared with its initial position
    /// @dev Refer to the whitepaper or the doc for the formulas of the `cashOutAmount`
    /// @dev The notion of `maintenanceMargin` is standard in centralized platforms offering perpetual futures
    function _getCashOutAmount(uint256 perpetualID, uint256 rate)
        internal
        view
        returns (uint256 newCashOutAmount, uint256 reachMaintenanceMargin)
    {
        Perpetual memory perpetual = perpetualData[perpetualID];
        // All these computations are made just because we are working with uint and not int
        // so we cannot do x-y if x<y!
        uint256 newCommit = (perpetual.committedAmount * perpetual.initialRate) / rate;
        // Checks if a liquidation is needed
        reachMaintenanceMargin = 0;
        if (newCommit >= perpetual.committedAmount + perpetual.cashOutAmount) newCashOutAmount = 0;
        else {
            newCashOutAmount = perpetual.committedAmount + perpetual.cashOutAmount - newCommit;
            if (newCashOutAmount <= (perpetual.cashOutAmount * maintenanceMargin) / BASE) reachMaintenanceMargin = 1;
        }
    }

    /// @notice Calls the oracle to read both Chainlink and Uniswap rates
    /// @return The lowest oracle value (between Chainlink and Uniswap) is the first outputted value
    /// @return The highest oracle value is the second output
    /// @dev If the oracle only involves a single oracle fees (like just Chainlink for USD-EUR),
    /// the same value will be returned twice
    function _getOraclePrice() internal view returns (uint256, uint256) {
        return _oracle.readAll();
    }

    /// @notice Computes the incentive for the keeper as a function of the fees initially taken to the HA
    /// and the margin ratio of the corresponding perpetual
    /// @param ratio Ratio between what's covered by the perpetual and the gap between what's covered
    /// and what's really to cover
    /// @param originalFees Amount of fees paid by the perpetual owner at creation
    /// @return keeperFeesCapped The amount of rewards going to the keeper
    /// @dev This internal function is computed each time fees need to be distributed to keepers intervening
    /// for HAs
    /// @dev In case of a keeper intervening in a liquidation, the `ratio` parameter needs to be null
    function _computeKeeperHAFees(uint256 ratio, uint256 originalFees) internal view returns (uint256) {
        uint256 rateFeeHA;
        if (ratio == 0) {
            // This corresponds to the case of a perpetual liquidation or of a perpetual being cashed because
            // of a too high leverage
            rateFeeHA = keeperFeesRatio;
        } else {
            // This corresponds to the case of a perpetual being cashed out because too much is covered by HAs
            rateFeeHA = _piecewiseLinear(ratio, xKeeperFeesCashOut, yKeeperFeesCashOut);
        }
        // Checking if the rewards do not exceed the maximum rewards amount that can be given to keepers
        uint256 keeperFees = (originalFees * rateFeeHA) / BASE;
        uint256 keeperFeesCapped = keeperFees < keeperFeesCap ? keeperFees : keeperFeesCap;
        return keeperFeesCapped;
    }

    // =========================== Fee Computation =================================

    /// @notice Gets the value of the fees and the net amount corrected from the fees in case of
    /// a deposit or a withdraw of collateral from a HA perpetual
    /// @param amount Amount to deposit or withdraw from the perpetual
    /// @param oracleRate Value of the oracle
    /// @param entry Checker to see if the transaction is a deposit or a withdraw
    /// @return netAmount Amount that will be either written in the perpetual as the `cashOutAmount` or
    /// given back to the HA
    /// @return fees Fees induced by this transaction
    function _getNetAmountAndFeesUpdate(
        uint256 amount,
        uint256 oracleRate,
        uint256 entry
    ) internal view returns (uint256 netAmount, uint256 fees) {
        // In the case of an update, the amount committed by the vault stays the same, hence the first value
        // provided to the `_computeCoverageMargin` is a zero
        uint256 margin = _computeCoverageMargin(0, oracleRate);
        // Computing the amount brought to add in the perpetual by deducing fees
        if (entry > 0) {
            netAmount = _computeFeeHADeposit(amount, margin);
        } else {
            netAmount = _computeFeeHAWithdraw(amount, margin);
        }
        fees = amount - netAmount;
    }

    /// @notice Gets the value of the fees and the net amount corrected from the fees in case of perpetual creation
    /// @param committedAmount Committed amount in the perpetual
    /// @param broughtAmount The brought amount in the perpetual at creation
    /// @param oracleRate Value of the oracle
    /// @return netBroughtAmount Amount that will be written in the perpetual as the `cashOutAmount`
    /// @return fees Fees induced by this transaction
    function _getNetAmountAndFeesCreation(
        uint256 broughtAmount,
        uint256 committedAmount,
        uint256 oracleRate
    ) internal view returns (uint256 netBroughtAmount, uint256 fees) {
        // Checking if the HA has the right to create a perpetual with such amount
        // If too much is already covered by HAs, the HA will not be able to create a perpetual
        uint256 margin = _computeCoverageMargin(committedAmount, oracleRate);
        require(margin > 0, "too much collateral covered");
        // Computing the net amount brought by the HAs to store in the perpetual
        // It consists simply in deducing fees that depend on how much is already covered
        // by HAs compared with what's to cover
        netBroughtAmount = _computeFeeHADeposit(broughtAmount, margin);
        fees = broughtAmount - netBroughtAmount;
    }

    /// @notice Gets the value of the margin that is the ratio between the gap of collateral to cover
    /// and the total amount to cover
    /// @param committedAmount Amount to add to the current total amount committed
    /// @param oracleRate Value of the oracle
    /// @return margin Ratio between the gap of collateral to cover and the total amount to cover
    function _computeCoverageMargin(uint256 committedAmount, uint256 oracleRate)
        internal
        view
        returns (uint256 margin)
    {
        (uint256 currentCAmount, uint256 maxCAmount) = _testMaxCAmount(committedAmount, oracleRate);
        if (currentCAmount < maxCAmount) margin = ((maxCAmount - currentCAmount) * BASE) / maxCAmount;
        else margin = 0;
    }

    /// @notice Helps to compute the net amount to add to a HA perpetual by deducing the fees from a given amount
    /// @param amount Raw value we need to reimburse
    /// @param gapMaxCAmount Coverage ratio (margin between the insured stocks and the stable seekers
    /// collateral to insure)
    /// @dev `amount` should be expressed in `collatBase` and `gapMaxCAmount` should be in `BASE`
    /// @dev The result is expressed in `collatBase`
    function _computeFeeHADeposit(uint256 amount, uint256 gapMaxCAmount) internal view returns (uint256) {
        uint256 haFeesDeposit = _piecewiseLinear(gapMaxCAmount, xHAFeesDeposit, yHAFeesDeposit);
        haFeesDeposit = (haFeesDeposit * haBonusMalusDeposit) / BASE;
        return (amount * (BASE - haFeesDeposit)) / BASE;
    }

    /// @notice Helps to compute the net amount to withdraw from a HA perpetual by deducing exit fees
    /// @param amount Raw value we need to reimburse
    /// @param gapMaxCAmount Utilization ratio, that is margin between the insured collateral
    /// and the stable seekers collateral to insure
    /// @dev `amount` should be expressed in `collatBase` and `gapMaxCAmount` should be in `BASE`
    /// @dev The result is expressed in `collatBase`
    function _computeFeeHAWithdraw(uint256 amount, uint256 gapMaxCAmount) internal view returns (uint256) {
        uint256 haFeesWithdraw = _piecewiseLinear(gapMaxCAmount, xHAFeesWithdraw, yHAFeesWithdraw);
        haFeesWithdraw = (haFeesWithdraw * haBonusMalusWithdraw) / BASE;
        return (amount * (BASE - haFeesWithdraw)) / BASE;
    }

    // ========================= Reward Distribution ===============================

    /// @notice View function to query the last timestamp a reward was distributed
    /// @return Current timestamp if a reward is being distributed or the last timestep
    function _lastTimeRewardApplicable() internal view returns (uint256) {
        uint256 returnValue = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        return returnValue;
    }

    /// @notice Used to actualize the `rewardPerTokenStored`
    /// @dev It adds to the reward per token: the time elapsed since the `rewardPerTokenStored`
    /// was last updated multiplied by the `rewardRate` divided by the number of tokens
    function _rewardPerToken() internal view returns (uint256) {
        if (totalCAmount == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored + ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * BASE) / totalCAmount;
    }

    /// @notice Allows a perpetual owner to withdraw rewards
    /// @param perpetualID ID of the perpetual which accumulated tokens
    /// @dev Internal version of the `getReward` function
    /// @dev In case where an approved address calls to cash out a vault, rewards are still going to get distributed
    /// to the owner of the perpetual, and not necessarily to the address getting the proceeds of the perpetual
    function _getReward(uint256 perpetualID) internal {
        _updateReward(perpetualID);
        uint256 reward = rewards[perpetualID];
        if (reward > 0) {
            rewards[perpetualID] = 0;
            address owner = _owners[perpetualID];
            // Attention here, there may be reentrancy attacks because of the following call
            // to an external contract done before other things are modified, yet since the `rewardToken`
            // is mostly going to be a trusted contract controlled by governance (namely the ANGLE token), then
            // there is no point in putting an expensive `nonReentrant` modifier in the functions in `PerpetualManagerFront`
            // that allow indirect interactions with `_updateReward`. If new `rewardTokens` are set, we could think about
            // upgrading the `PerpetualManagerFront` contract
            rewardToken.safeTransfer(owner, reward);
            emit RewardPaid(owner, reward);
        }
    }

    /// @notice Allows to check the amount of gov tokens earned by a perpetual
    /// @param perpetualID ID of the perpetual which accumulated tokens
    /// @return Amount of gov tokens earned by the perpetual
    function _earned(uint256 perpetualID) internal view returns (uint256) {
        return
            (perpetualData[perpetualID].committedAmount *
                (_rewardPerToken() - perpetualRewardPerTokenPaid[perpetualID])) /
            BASE +
            rewards[perpetualID];
    }

    /// @notice Updates the amount of gov tokens earned by a perpetual
    /// @param perpetualID of the perpetual which earns tokens
    /// @dev When this function is called in the code, it has already been checked that the `perpetualID`
    /// exists
    function _updateReward(uint256 perpetualID) internal {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();
        // No need to check if the `perpetualID` exists here, it has already been checked
        // in the code before when this internal function is called
        rewards[perpetualID] = _earned(perpetualID);
        perpetualRewardPerTokenPaid[perpetualID] = rewardPerTokenStored;
    }

    // =============================== ERC721 Logic ================================

    /// @notice Gets the owner of a perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @return Owner of the perpetual
    function _ownerOf(uint256 perpetualID) internal view returns (address) {
        address owner = _owners[perpetualID];
        require(owner != address(0), "nonexistent perpetual");
        return owner;
    }

    /// @notice Gets the addresses approved for a perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @return Address approved for this perpetual
    function _getApproved(uint256 perpetualID) internal view returns (address) {
        require(_exists(perpetualID), "nonexistent perpetual");
        return _perpetualApprovals[perpetualID];
    }

    /// @notice Safely transfers `perpetualID` token from `from` to `to`, checking first that contract recipients
    /// are aware of the ERC721 protocol to prevent tokens from being forever locked
    /// @param perpetualID ID of the concerned perpetual
    /// @param _data Additional data, it has no specified format and it is sent in call to `to`
    /// @dev This internal function is equivalent to {safeTransferFrom}, and can be used to e.g.
    /// implement alternative mechanisms to perform token transfer, such as signature-based
    /// @dev Requirements:
    ///     - `from` cannot be the zero address.
    ///     - `to` cannot be the zero address.
    ///     - `perpetualID` token must exist and be owned by `from`.
    ///     - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
    function _safeTransfer(
        address from,
        address to,
        uint256 perpetualID,
        bytes memory _data
    ) internal virtual {
        _transfer(from, to, perpetualID);
        require(_checkOnERC721Received(from, to, perpetualID, _data), "transfer to non ERC721Receiver implementer");
    }

    /// @notice Returns whether `perpetualID` exists
    /// @dev Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}
    /// @dev Tokens start existing when they are minted (`_mint`),
    /// and stop existing when they are burned (`_burn`)
    function _exists(uint256 perpetualID) internal view virtual returns (bool) {
        return _owners[perpetualID] != address(0);
    }

    /// @notice Returns whether `spender` is allowed to manage `perpetualID`
    /// @dev `perpetualID` must exist
    function _isApprovedOrOwner(address spender, uint256 perpetualID) internal view virtual returns (bool) {
        require(_exists(perpetualID), "nonexistent perpetual");
        address owner = _ownerOf(perpetualID);
        return (spender == owner || _getApproved(perpetualID) == spender || _operatorApprovals[owner][spender]);
    }

    /// @notice Mints `perpetualID` and transfers it to `to`
    /// @dev Usage of this method is discouraged, use {_safeMint} whenever possible
    /// @dev `perpetualID` must not exist and `to` cannot be the zero address
    /// @dev Emits a {Transfer} event
    function _mint(address to, uint256 perpetualID) internal virtual {
        _balances[to] += 1;
        _owners[perpetualID] = to;

        emit Transfer(address(0), to, perpetualID);
    }

    /// @notice Destroys `perpetualID`
    /// @dev `perpetualID` must exist
    /// @dev Emits a {Transfer} event
    function _burn(uint256 perpetualID) internal virtual {
        address owner = _ownerOf(perpetualID);

        // Clear approvals
        _approve(address(0), perpetualID);

        _balances[owner] -= 1;
        delete _owners[perpetualID];
        delete perpetualData[perpetualID];

        emit Transfer(owner, address(0), perpetualID);
    }

    /// @notice Transfers `perpetualID` from `from` to `to` as opposed to {transferFrom},
    /// this imposes no restrictions on msg.sender
    /// @dev `to` cannot be the zero address and `perpetualID` must be owned by `from`
    /// @dev Emits a {Transfer} event
    function _transfer(
        address from,
        address to,
        uint256 perpetualID
    ) internal virtual {
        require(_ownerOf(perpetualID) == from, "incorrect caller");
        require(to != address(0), "transfer to the zero address");

        // Clear approvals from the previous owner
        _approve(address(0), perpetualID);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[perpetualID] = to;

        emit Transfer(from, to, perpetualID);
    }

    /// @notice Approves `to` to operate on `perpetualID`
    function _approve(address to, uint256 perpetualID) internal virtual {
        _perpetualApprovals[perpetualID] = to;
    }

    /// @notice Internal function to invoke {IERC721Receiver-onERC721Received} on a target address
    /// The call is not executed if the target address is not a contract
    /// @param from Address representing the previous owner of the given token ID
    /// @param to Target address that will receive the tokens
    /// @param perpetualID ID of the token to be transferred
    /// @param _data Bytes optional data to send along with the call
    /// @return Bool whether the call correctly returned the expected magic value
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 perpetualID,
        bytes memory _data
    ) private returns (bool) {
        if (to.isContract()) {
            try IERC721ReceiverUpgradeable(to).onERC721Received(msg.sender, from, perpetualID, _data) returns (
                bytes4 retval
            ) {
                return retval == IERC721ReceiverUpgradeable(to).onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ERC721Receiver not implemented");
                } else {
                    // solhint-disable-next-line no-inline-assembly
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }
}
