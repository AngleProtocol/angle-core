// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./PerpetualManagerStorage.sol";

/// @title PerpetualManagerInternal
/// @author Angle Core Team
/// @notice `PerpetualManager` is the contract handling all the Hedging Agents perpetuals
/// @dev There is one `PerpetualManager` contract per pair stablecoin/collateral in the protocol
/// @dev This file contains all the internal functions of the `PerpetualManager` contract
contract PerpetualManagerInternal is PerpetualManagerStorage {
    using Address for address;
    using SafeERC20 for IERC20;

    // ======================== State Modifying Functions ==========================

    /// @notice Cashes out a perpetual, which means that it simply deletes the references to the perpetual
    /// in the contract
    /// @param perpetualID ID of the perpetual
    /// @param perpetual Data of the perpetual
    function _closePerpetual(uint256 perpetualID, Perpetual memory perpetual) internal {
        // Handling the staking logic
        // Reward should always be updated before the `totalHedgeAmount`
        // Rewards are distributed to the perpetual which is liquidated
        uint256 hedge = perpetual.committedAmount * perpetual.entryRate;
        _getReward(perpetualID, hedge);
        delete perpetualRewardPerTokenPaid[perpetualID];

        // Updating `totalHedgeAmount` to represent the fact that less money is insured
        totalHedgeAmount -= hedge / _collatBase;

        _burn(perpetualID);
    }

    /// @notice Allows the protocol to transfer collateral to an address while handling the case where there are
    /// not enough reserves
    /// @param owner Address of the receiver
    /// @param amount The amount of collateral sent
    /// @dev If there is not enough collateral in balance (this can happen when money has been lent to strategies),
    /// then the owner is reimbursed by receiving what is missing in sanTokens at the correct value
    function _secureTransfer(address owner, uint256 amount) internal {
        uint256 curBalance = poolManager.getBalance();
        if (curBalance >= amount && amount > 0) {
            // Case where there is enough in reserves to reimburse the person
            _token.safeTransferFrom(address(poolManager), owner, amount);
        } else if (amount > 0) {
            // When there is not enough to reimburse the entire amount, the protocol reimburses
            // what it can using its reserves and the rest is paid in sanTokens at the current
            // exchange rate
            uint256 amountLeft = amount - curBalance;
            _token.safeTransferFrom(address(poolManager), owner, curBalance);
            _stableMaster.convertToSLP(amountLeft, owner);
        }
    }

    /// @notice Checks whether the perpetual should be liquidated or not, and if so liquidates the perpetual
    /// @param perpetualID ID of the perpetual to check and potentially liquidate
    /// @param perpetual Data of the perpetual to check
    /// @param rateDown Oracle value to compute the cash out amount of the perpetual
    /// @return Cash out amount of the perpetual
    /// @return Whether the perpetual was liquidated or not
    /// @dev Generally, to check for the liquidation of a perpetual, we use the lowest oracle value possible:
    /// it's the one that is most at the advantage of the protocol, hence the `rateDown` parameter
    function _checkLiquidation(
        uint256 perpetualID,
        Perpetual memory perpetual,
        uint256 rateDown
    ) internal returns (uint256, uint256) {
        uint256 liquidated;
        (uint256 cashOutAmount, uint256 reachMaintenanceMargin) = _getCashOutAmount(perpetual, rateDown);
        if (cashOutAmount == 0 || reachMaintenanceMargin == 1) {
            _closePerpetual(perpetualID, perpetual);
            // No need for an event to find out that a perpetual is liquidated
            liquidated = 1;
        }
        return (cashOutAmount, liquidated);
    }

    // ========================= Internal View Functions ===========================

    /// @notice Gets the current cash out amount of a perpetual
    /// @param perpetual Data of the concerned perpetual
    /// @param rate Value of the oracle
    /// @return cashOutAmount Amount that the HA could get by closing this perpetual
    /// @return reachMaintenanceMargin Whether the position of the perpetual is now too small
    /// compared with its initial position
    /// @dev Refer to the whitepaper or the doc for the formulas of the cash out amount
    /// @dev The notion of `maintenanceMargin` is standard in centralized platforms offering perpetual futures
    function _getCashOutAmount(Perpetual memory perpetual, uint256 rate)
        internal
        view
        returns (uint256 cashOutAmount, uint256 reachMaintenanceMargin)
    {
        // All these computations are made just because we are working with uint and not int
        // so we cannot do x-y if x<y
        uint256 newCommit = (perpetual.committedAmount * perpetual.entryRate) / rate;
        // Checking if a liquidation is needed: for this to happen the `cashOutAmount` should be inferior
        // to the maintenance margin of the perpetual
        reachMaintenanceMargin;
        if (newCommit >= perpetual.committedAmount + perpetual.margin) cashOutAmount = 0;
        else {
            // The definition of the margin ratio is `(margin + PnL) / committedAmount`
            // where `PnL = commit * (1-entryRate/currentRate)`
            // So here: `newCashOutAmount = margin + PnL`
            cashOutAmount = perpetual.committedAmount + perpetual.margin - newCommit;
            if (cashOutAmount * BASE_PARAMS <= perpetual.committedAmount * maintenanceMargin)
                reachMaintenanceMargin = 1;
        }
    }

    /// @notice Calls the oracle to read both Chainlink and Uniswap rates
    /// @return The lowest oracle value (between Chainlink and Uniswap) is the first outputted value
    /// @return The highest oracle value is the second output
    /// @dev If the oracle only involves a single oracle fees (like just Chainlink for USD-EUR),
    /// the same value is returned twice
    function _getOraclePrice() internal view returns (uint256, uint256) {
        return oracle.readAll();
    }

    /// @notice Computes the incentive for the keeper as a function of the cash out amount of a liquidated perpetual
    /// which value falls below its maintenance margin
    /// @param cashOutAmount Value remaining in the perpetual
    /// @dev By computing keeper fees as a fraction of the cash out amount of a perpetual rather than as a fraction
    /// of the `committedAmount`, keepers are incentivized to react fast when a perpetual is below the maintenance margin
    /// @dev Perpetual exchange protocols typically compute liquidation fees using an equivalent of the `committedAmount`,
    /// this is not the case here
    function _computeKeeperLiquidationFees(uint256 cashOutAmount) internal view returns (uint256 keeperFees) {
        keeperFees = (cashOutAmount * keeperFeesLiquidationRatio) / BASE_PARAMS;
        keeperFees = keeperFees < keeperFeesLiquidationCap ? keeperFees : keeperFeesLiquidationCap;
    }

    /// @notice Gets the value of the hedge ratio that is the ratio between the amount currently hedged by HAs
    /// and the target amount that should be hedged by them
    /// @param currentHedgeAmount Amount currently covered by HAs
    /// @return ratio Ratio between the amount of collateral (in stablecoin value) currently hedged
    /// and the target amount to hedge
    function _computeHedgeRatio(uint256 currentHedgeAmount) internal view returns (uint64 ratio) {
        // Fetching info from the `StableMaster`: the amount to hedge is based on the `stocksUsers`
        // of the given collateral
        uint256 targetHedgeAmount = (_stableMaster.getStocksUsers() * targetHAHedge) / BASE_PARAMS;
        if (currentHedgeAmount < targetHedgeAmount)
            ratio = uint64((currentHedgeAmount * BASE_PARAMS) / targetHedgeAmount);
        else ratio = uint64(BASE_PARAMS);
    }

    // =========================== Fee Computation =================================

    /// @notice Gets the net margin corrected from the fees at perpetual opening
    /// @param margin Amount brought in the perpetual at creation
    /// @param totalHedgeAmountUpdate Amount of stablecoins that this perpetual is going to insure
    /// @param committedAmount Committed amount in the perpetual, we need it to compute the fees
    /// paid by the HA
    /// @return netMargin Amount that will be written in the perpetual as the `margin`
    /// @dev The amount of stablecoins insured by a perpetual is `committedAmount * oracleRate / _collatBase`
    function _getNetMargin(
        uint256 margin,
        uint256 totalHedgeAmountUpdate,
        uint256 committedAmount
    ) internal view returns (uint256 netMargin) {
        // Checking if the HA has the right to open a perpetual with such amount
        // If HAs hedge more than the target amount, then new HAs will not be able to create perpetuals
        // The amount hedged by HAs after opening the perpetual is going to be:
        uint64 ratio = _computeHedgeRatio(totalHedgeAmount + totalHedgeAmountUpdate);
        require(ratio < uint64(BASE_PARAMS), "25");
        // Computing the net margin of HAs to store in the perpetual: it consists simply in deducing fees
        // Those depend on how much is already hedged by HAs compared with what's to hedge
        uint256 haFeesDeposit = (haBonusMalusDeposit * _piecewiseLinear(ratio, xHAFeesDeposit, yHAFeesDeposit)) /
            BASE_PARAMS;
        // Fees are rounded to the advantage of the protocol
        haFeesDeposit = committedAmount - (committedAmount * (BASE_PARAMS - haFeesDeposit)) / BASE_PARAMS;
        // Fees are computed based on the committed amount of the perpetual
        // The following reverts if fees are too big compared to the margin
        netMargin = margin - haFeesDeposit;
    }

    /// @notice Gets the net amount to give to a HA (corrected from the fees) in case of a perpetual closing
    /// @param committedAmount Committed amount in the perpetual
    /// @param cashOutAmount The current cash out amount of the perpetual
    /// @param ratio What's hedged divided by what's to hedge
    /// @return netCashOutAmount Amount that will be distributed to the HA
    /// @return feesPaid Amount of fees paid by the HA at perpetual closing
    /// @dev This function is called by the `closePerpetual` and by the `forceClosePerpetuals`
    /// function
    /// @dev The amount of fees paid by the HA is used to compute the incentive given to HAs closing perpetuals
    /// when too much is covered
    function _getNetCashOutAmount(
        uint256 cashOutAmount,
        uint256 committedAmount,
        uint64 ratio
    ) internal view returns (uint256 netCashOutAmount, uint256 feesPaid) {
        feesPaid = (haBonusMalusWithdraw * _piecewiseLinear(ratio, xHAFeesWithdraw, yHAFeesWithdraw)) / BASE_PARAMS;
        // Rounding the fees at the protocol's advantage
        feesPaid = committedAmount - (committedAmount * (BASE_PARAMS - feesPaid)) / BASE_PARAMS;
        if (feesPaid >= cashOutAmount) {
            netCashOutAmount = 0;
            feesPaid = cashOutAmount;
        } else {
            netCashOutAmount = cashOutAmount - feesPaid;
        }
    }

    // ========================= Reward Distribution ===============================

    /// @notice View function to query the last timestamp at which a reward was distributed
    /// @return Current timestamp if a reward is being distributed or the last timestamp
    function _lastTimeRewardApplicable() internal view returns (uint256) {
        uint256 returnValue = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        return returnValue;
    }

    /// @notice Used to actualize the `rewardPerTokenStored`
    /// @dev It adds to the reward per token: the time elapsed since the `rewardPerTokenStored`
    /// was last updated multiplied by the `rewardRate` divided by the number of tokens
    /// @dev Specific attention should be placed on the base here: `rewardRate` is in the base of the reward token
    /// and `totalHedgeAmount` is in `BASE_TOKENS` here: as this function concerns an amount of reward
    /// tokens, the output of this function should be in the base of the reward token too
    function _rewardPerToken() internal view returns (uint256) {
        if (totalHedgeAmount == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * BASE_TOKENS) /
            totalHedgeAmount;
    }

    /// @notice Allows a perpetual owner to withdraw rewards
    /// @param perpetualID ID of the perpetual which accumulated tokens
    /// @param hedge Perpetual commit amount times the entry rate
    /// @dev Internal version of the `getReward` function
    /// @dev In case where an approved address calls to close a perpetual, rewards are still going to get distributed
    /// to the owner of the perpetual, and not necessarily to the address getting the proceeds of the perpetual
    function _getReward(uint256 perpetualID, uint256 hedge) internal {
        _updateReward(perpetualID, hedge);
        uint256 reward = rewards[perpetualID];
        if (reward > 0) {
            rewards[perpetualID] = 0;
            address owner = _owners[perpetualID];
            // Attention here, there may be reentrancy attacks because of the following call
            // to an external contract done before other things are modified. Yet since the `rewardToken`
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
    /// @param hedge Perpetual commit amount times the entry rate
    /// @return Amount of gov tokens earned by the perpetual
    /// @dev A specific attention should be paid to have the base here: we consider that each HA stakes an amount
    /// equal to `committedAmount * entryRate / _collatBase`, here as the `hedge` corresponds to `committedAmount * entryRate`,
    /// we just need to divide by `_collatBase`
    /// @dev HAs earn reward tokens which are in base `BASE_TOKENS`
    function _earned(uint256 perpetualID, uint256 hedge) internal view returns (uint256) {
        return
            (hedge * (_rewardPerToken() - perpetualRewardPerTokenPaid[perpetualID])) /
            BASE_TOKENS /
            _collatBase +
            rewards[perpetualID];
    }

    /// @notice Updates the amount of gov tokens earned by a perpetual
    /// @param perpetualID of the perpetual which earns tokens
    /// @param hedge Perpetual commit amount times the entry rate
    /// @dev When this function is called in the code, it has already been checked that the `perpetualID`
    /// exists
    function _updateReward(uint256 perpetualID, uint256 hedge) internal {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();
        // No need to check if the `perpetualID` exists here, it has already been checked
        // in the code before when this internal function is called
        rewards[perpetualID] = _earned(perpetualID, hedge);
        perpetualRewardPerTokenPaid[perpetualID] = rewardPerTokenStored;
    }

    // =============================== ERC721 Logic ================================

    /// @notice Gets the owner of a perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @return owner Owner of the perpetual
    function _ownerOf(uint256 perpetualID) internal view returns (address owner) {
        owner = _owners[perpetualID];
        require(owner != address(0), "2");
    }

    /// @notice Gets the addresses approved for a perpetual
    /// @param perpetualID ID of the concerned perpetual
    /// @return Address approved for this perpetual
    function _getApproved(uint256 perpetualID) internal view returns (address) {
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
    ) internal {
        _transfer(from, to, perpetualID);
        require(_checkOnERC721Received(from, to, perpetualID, _data), "24");
    }

    /// @notice Returns whether `perpetualID` exists
    /// @dev Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}
    /// @dev Tokens start existing when they are minted (`_mint`),
    /// and stop existing when they are burned (`_burn`)
    function _exists(uint256 perpetualID) internal view returns (bool) {
        return _owners[perpetualID] != address(0);
    }

    /// @notice Returns whether `spender` is allowed to manage `perpetualID`
    /// @dev `perpetualID` must exist
    function _isApprovedOrOwner(address spender, uint256 perpetualID) internal view returns (bool) {
        // The following checks if the perpetual exists
        address owner = _ownerOf(perpetualID);
        return (spender == owner || _getApproved(perpetualID) == spender || _operatorApprovals[owner][spender]);
    }

    /// @notice Mints `perpetualID` and transfers it to `to`
    /// @dev This method is equivalent to the `_safeMint` method used in OpenZeppelin ERC721 contract
    /// @dev `perpetualID` must not exist and `to` cannot be the zero address
    /// @dev Before calling this function it is checked that the `perpetualID` does not exist as it
    /// comes from a counter that has been incremented
    /// @dev Emits a {Transfer} event
    function _mint(address to, uint256 perpetualID) internal {
        _balances[to] += 1;
        _owners[perpetualID] = to;
        emit Transfer(address(0), to, perpetualID);
        require(_checkOnERC721Received(address(0), to, perpetualID, ""), "24");
    }

    /// @notice Destroys `perpetualID`
    /// @dev `perpetualID` must exist
    /// @dev Emits a {Transfer} event
    function _burn(uint256 perpetualID) internal {
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
    ) internal {
        require(_ownerOf(perpetualID) == from, "1");
        require(to != address(0), "26");

        // Clear approvals from the previous owner
        _approve(address(0), perpetualID);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[perpetualID] = to;

        emit Transfer(from, to, perpetualID);
    }

    /// @notice Approves `to` to operate on `perpetualID`
    function _approve(address to, uint256 perpetualID) internal {
        _perpetualApprovals[perpetualID] = to;
        emit Approval(_ownerOf(perpetualID), to, perpetualID);
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
                    revert("24");
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
