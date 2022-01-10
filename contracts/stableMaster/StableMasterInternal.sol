// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./StableMasterStorage.sol";

/// @title StableMasterInternal
/// @author Angle Core Team
/// @notice `StableMaster` is the contract handling all the collateral types accepted for a given stablecoin
/// It does all the accounting and is the point of entry in the protocol for stable holders and seekers as well as SLPs
/// @dev This file contains all the internal function of the `StableMaster` contract
contract StableMasterInternal is StableMasterStorage, PausableMapUpgradeable {
    /// @notice Checks if the `msg.sender` calling the contract has the right to do it
    /// @param col Struct for the collateral associated to the caller address
    /// @dev Since the `StableMaster` contract uses a `contractMap` that stores addresses of some verified
    /// protocol's contracts in it, and since the roles corresponding to these addresses are never admin roles
    /// it is cheaper not to use for these contracts OpenZeppelin's access control logic
    /// @dev A non null associated token address is what is used to check if a `PoolManager` has well been initialized
    /// @dev We could set `PERPETUALMANAGER_ROLE`, `POOLMANAGER_ROLE` and `FEEMANAGER_ROLE` for this
    /// contract, but this would actually be inefficient
    function _contractMapCheck(Collateral storage col) internal view {
        require(address(col.token) != address(0), "3");
    }

    /// @notice Checks if the protocol has been paused for an agent and for a given collateral type for this
    /// stablecoin
    /// @param agent Name of the agent to check, it is either going to be `STABLE` or `SLP`
    /// @param poolManager `PoolManager` contract for which to check pauses
    function _whenNotPaused(bytes32 agent, address poolManager) internal view {
        require(!paused[keccak256(abi.encodePacked(agent, poolManager))], "18");
    }

    /// @notice Updates the `sanRate` that is the exchange rate between sanTokens given to SLPs and collateral or
    /// accumulates fees to be distributed to SLPs before doing it at next block
    /// @param toShare Amount of interests that needs to be redistributed to the SLPs through the `sanRate`
    /// @param col Struct for the collateral of interest here which values are going to be updated
    /// @dev This function can only increase the `sanRate` and is not used to take into account a loss made through
    /// lending or another yield farming strategy: this is done in the `signalLoss` function
    /// @dev The `sanRate` is only be updated from the fees accumulated from previous blocks and the fees to share to SLPs
    /// are just accumulated to be distributed at next block
    /// @dev A flashloan attack could consist in seeing fees to be distributed, deposit, increase the `sanRate` and then
    /// withdraw: what is done with the `lockedInterests` parameter is a way to mitigate that
    /// @dev Another solution against flash loans would be to have a non null `slippage` at all times: this is far from ideal
    /// for SLPs in the first place
    function _updateSanRate(uint256 toShare, Collateral storage col) internal {
        uint256 _lockedInterests = col.slpData.lockedInterests;
        // Checking if the `sanRate` has been updated in the current block using past block fees
        // This is a way to prevent flash loans attacks when an important amount of fees are going to be distributed
        // in a block: fees are stored but will just be distributed to SLPs who will be here during next blocks
        if (block.timestamp != col.slpData.lastBlockUpdated && _lockedInterests > 0) {
            uint256 sanMint = col.sanToken.totalSupply();
            if (sanMint != 0) {
                // Checking if the update is too important and should be made in multiple blocks
                if (_lockedInterests > col.slpData.maxInterestsDistributed) {
                    // `sanRate` is expressed in `BASE_TOKENS`
                    col.sanRate += (col.slpData.maxInterestsDistributed * BASE_TOKENS) / sanMint;
                    _lockedInterests -= col.slpData.maxInterestsDistributed;
                } else {
                    col.sanRate += (_lockedInterests * BASE_TOKENS) / sanMint;
                    _lockedInterests = 0;
                }
                emit SanRateUpdated(address(col.token), col.sanRate);
            } else {
                _lockedInterests = 0;
            }
        }
        // Adding the fees to be distributed at next block
        if (toShare != 0) {
            if ((col.slpData.slippageFee == 0) && (col.slpData.feesAside != 0)) {
                // If the collateral ratio is big enough, all the fees or gains will be used to update the `sanRate`
                // If there were fees or lending gains that had been put aside, they will be added in this case to the
                // update of the `sanRate`
                toShare += col.slpData.feesAside;
                col.slpData.feesAside = 0;
            } else if (col.slpData.slippageFee != 0) {
                // Computing the fraction of fees and gains that should be left aside if the collateral ratio is too small
                uint256 aside = (toShare * col.slpData.slippageFee) / BASE_PARAMS;
                toShare -= aside;
                // The amount of fees left aside should be rounded above
                col.slpData.feesAside += aside;
            }
            // Updating the amount of fees to be distributed next block
            _lockedInterests += toShare;
        }
        col.slpData.lockedInterests = _lockedInterests;
        col.slpData.lastBlockUpdated = block.timestamp;
    }

    /// @notice Computes the current fees to be taken when minting using `amount` of collateral
    /// @param amount Amount of collateral in the transaction to get stablecoins
    /// @param col Struct for the collateral of interest
    /// @return feeMint Mint Fees taken to users expressed in collateral
    /// @dev Fees depend on the hedge ratio that is the ratio between what is hedged by HAs and what should be hedged
    /// @dev The more is hedged by HAs, the smaller fees are expected to be
    /// @dev Fees are also corrected by the `bonusMalusMint` parameter which induces a dependence in collateral ratio
    function _computeFeeMint(uint256 amount, Collateral storage col) internal view returns (uint256 feeMint) {
        uint64 feeMint64;
        if (col.feeData.xFeeMint.length == 1) {
            // This is done to avoid an external call in the case where the fees are constant regardless of the collateral
            // ratio
            feeMint64 = col.feeData.yFeeMint[0];
        } else {
            uint64 hedgeRatio = _computeHedgeRatio(amount + col.stocksUsers, col);
            // Computing the fees based on the spread
            feeMint64 = _piecewiseLinear(hedgeRatio, col.feeData.xFeeMint, col.feeData.yFeeMint);
        }
        // Fees could in some occasions depend on other factors like collateral ratio
        // Keepers are the ones updating this part of the fees
        feeMint = (feeMint64 * col.feeData.bonusMalusMint) / BASE_PARAMS;
    }

    /// @notice Computes the current fees to be taken when burning stablecoins
    /// @param amount Amount of collateral corresponding to the stablecoins burnt in the transaction
    /// @param col Struct for the collateral of interest
    /// @return feeBurn Burn fees taken to users expressed in collateral
    /// @dev The amount is obtained after the amount of agTokens sent is converted in collateral
    /// @dev Fees depend on the hedge ratio that is the ratio between what is hedged by HAs and what should be hedged
    /// @dev The more is hedged by HAs, the higher fees are expected to be
    /// @dev Fees are also corrected by the `bonusMalusBurn` parameter which induces a dependence in collateral ratio
    function _computeFeeBurn(uint256 amount, Collateral storage col) internal view returns (uint256 feeBurn) {
        uint64 feeBurn64;
        if (col.feeData.xFeeBurn.length == 1) {
            // Avoiding an external call if fees are constant
            feeBurn64 = col.feeData.yFeeBurn[0];
        } else {
            uint64 hedgeRatio = _computeHedgeRatio(col.stocksUsers - amount, col);
            // Computing the fees based on the spread
            feeBurn64 = _piecewiseLinear(hedgeRatio, col.feeData.xFeeBurn, col.feeData.yFeeBurn);
        }
        // Fees could in some occasions depend on other factors like collateral ratio
        // Keepers are the ones updating this part of the fees
        feeBurn = (feeBurn64 * col.feeData.bonusMalusBurn) / BASE_PARAMS;
    }

    /// @notice Computes the hedge ratio that is the ratio between the amount of collateral hedged by HAs
    /// divided by the amount that should be hedged
    /// @param newStocksUsers Value of the collateral from users to hedge
    /// @param col Struct for the collateral of interest
    /// @return ratio Ratio between what's hedged divided what's to hedge
    /// @dev This function is typically called to compute mint or burn fees
    /// @dev It seeks from the `PerpetualManager` contract associated to the collateral the total amount
    /// already hedged by HAs and compares it to the amount to hedge
    function _computeHedgeRatio(uint256 newStocksUsers, Collateral storage col) internal view returns (uint64 ratio) {
        // Fetching the amount hedged by HAs from the corresponding `perpetualManager` contract
        uint256 totalHedgeAmount = col.perpetualManager.totalHedgeAmount();
        newStocksUsers = (col.feeData.targetHAHedge * newStocksUsers) / BASE_PARAMS;
        if (newStocksUsers > totalHedgeAmount) ratio = uint64((totalHedgeAmount * BASE_PARAMS) / newStocksUsers);
        else ratio = uint64(BASE_PARAMS);
    }
}
