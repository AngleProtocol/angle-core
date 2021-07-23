// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

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
        require(address(col.token) != address(0), "invalid call");
    }

    /// @notice Checks if the protocol has been paused for an agent and for a given collateral type for this
    /// stablecoin
    /// @param agent Name of the agent to check, it is either going to be `STABLE` or `SLP`
    /// @param poolManager `PoolManager` contract for which to check pauses
    function _whenNotPaused(bytes32 agent, address poolManager) internal view {
        require(!paused(keccak256(abi.encodePacked(agent, poolManager))), "paused");
    }

    /// @notice Computes the amount of fees to be used to update the `sanRate` and adds the fees to the fees
    /// to be distributed at next block by SLPs
    /// @param feesInC Total amount of fees to share
    /// @param col Struct for the collateral of interest here which values are going to be updated
    function _accumulateFees(uint256 feesInC, Collateral storage col) internal {
        // Computing the portion of the fees that will be distributed to SLPs
        uint256 toShare = (feesInC * col.slpData.feesForSLPs) / BASE;
        // Updating the `sanRate`
        _updateSanRate(toShare, col);
    }

    /// @notice Updates the `sanRate` that is the exchange rate between sanTokens given to SLPs and collateral or
    /// accumulates fees to be distributed to SLPs before doing it at next block
    /// @param toShare Amount of interests that needs to be redistributed to the SLPs through the `sanRate`
    /// @param col Struct for the collateral of interest here which values are going to be updated
    /// @dev This function can only increase the `sanRate` and is not used to take into account a loss made through
    /// lending or another yield farming strategy: this is done in the `signalLoss` function
    /// @dev The `sanRate` will only be updated from the fees accumulated from previous blocks and the fees to distribute
    /// are just accumulated to be distributed at next block
    /// @dev A flashloan attack could consist in seeing fees to be distributed, deposit, increase the `sanRate` and then
    /// withdraw: what is done with the `lockedInterests` parameter is a way to mitigate that
    /// @dev Another solution against flash loans would be to have a non null `slippage` at all time: we would like to avoid
    /// that in the first place
    function _updateSanRate(uint256 toShare, Collateral storage col) internal {
        uint256 sanMint = col.sanToken.totalSupply();
        uint256 _lockedInterests = col.slpData.lockedInterests;
        // Checking if the `sanRate` has been updated in the current block using past block fees
        // This is a way to prevent flash loans attacks when an important amount of fees are going to be distributed
        // in a block: fees are stored but will just be distributed to SLPs who will be here during next blocks
        if (block.timestamp != col.slpData.lastBlockUpdated && _lockedInterests > 0) {
            if (sanMint != 0) {
                // Checking if the update is too important and should be made in multiple blocks
                if (col.slpData.lockedInterests > (sanMint * col.slpData.maxSanRateUpdate) / BASE) {
                    col.sanRate += col.slpData.maxSanRateUpdate;
                    // Substracting before dividing for rounding
                    _lockedInterests = (_lockedInterests * BASE - sanMint * col.slpData.maxSanRateUpdate) / BASE;
                } else {
                    col.sanRate += (_lockedInterests * BASE) / sanMint;
                    _lockedInterests = 0;
                }
                emit SanRateUpdated(col.sanRate, address(col.token));
            } else {
                _lockedInterests = 0;
            }
            col.slpData.lastBlockUpdated = block.timestamp;
        }
        // Adding the fees to be distributed at next block
        // Fees are only going to get added if there are SLPs
        if (toShare != 0 && sanMint != 0) {
            if ((col.slpData.slippageFee == 0) && (col.slpData.feesAside != 0)) {
                // If the collateral ratio is big enough, all the fees or gains will be used to update the `sanRate`
                // If there were fees or lending gains that had been put aside
                // they will be added in this case to the update of the `sanRate`
                toShare += col.slpData.feesAside;
                col.slpData.feesAside = 0;
            } else if (col.slpData.slippageFee != 0) {
                // Computing the fraction of fees and gains that should be left aside if the collateral ratio is too small
                uint256 aside = (toShare * col.slpData.slippageFee) / BASE;
                toShare -= aside;
                // The amount of fees left aside should be rounded above
                col.slpData.feesAside = col.slpData.feesAside + aside;
            }
            // Updating the amount of fees to be distributed next block
            _lockedInterests += toShare;
        }
        col.slpData.lockedInterests = _lockedInterests;
    }

    /// @notice Computes the current fees to be taken when minting using `amount` of collateral
    /// @param amount Amount of collateral in the transaction to get stablecoins
    /// @param col Struct for the collateral of interest
    /// @return feeMint Mint Fees taken to users expressed in collateral
    /// @dev Fees depend on HA coverage that is the proportion of collateral from users (`stocksUsers`) that is covered by HAs
    /// @dev The more is covered by HAs, the smaller fees are expected to be
    /// @dev Fees are also corrected by the `bonusMalusMint` parameter which induces a dependence in collateral ratio
    function _computeFeeMint(uint256 amount, Collateral storage col) internal view returns (uint256 feeMint) {
        // In case of a negative `stocksUsers` even after the entrance of the user we set a maximum fee to have a continuous
        // fee policy. If `stocksUsers` is negative and then positive with the user entrance, everything is done
        // as if the `stocksUser` was positive
        uint256 spread = BASE;
        if (col.stocksUsers > 0) {
            spread = _computeSpread(amount + uint256(col.stocksUsers), col);
        } else if (int256(amount) >= 0 && (int256(amount) + col.stocksUsers) > 0) {
            spread = _computeSpread(uint256(int256(amount) + col.stocksUsers), col);
        }
        // Computing the fees based on the spread
        feeMint = _piecewiseLinear(spread, col.feeData.xFeeMint, col.feeData.yFeeMint);
        // Fees could in some occasions depend on other factors like collateral ratio
        // Keepers are the ones updating this part of the fees
        feeMint = (feeMint * col.feeData.bonusMalusMint) / BASE;
    }

    /// @notice Computes the current fees to be taken when burning stablecoins and having the oracle value
    /// saying that `amount` of collateral should be given back
    /// @param amount Amount of collateral corresponding to the stablecoins burnt in the transaction
    /// @param col Struct for the collateral of interest
    /// @return feeBurn Burn fees taken to users expressed in collateral
    /// @dev The amount is obtained after the amount of agTokens sent is converted in collateral
    /// @dev Fees depend on HA coverage that is the proportion of collateral from users (`stocksUsers`) that is covered by HAs
    /// @dev The more is covered by HAs, the higher fees are expected to be
    /// @dev Fees are also corrected by the `bonusMalusBurn` parameter which induces a dependence in collateral ratio
    function _computeFeeBurn(uint256 amount, Collateral storage col) internal view returns (uint256 feeBurn) {
        uint256 spread = 0;
        if (col.stocksUsers >= 0 && (uint256(col.stocksUsers) > amount)) {
            spread = _computeSpread(uint256(col.stocksUsers) - amount, col);
        }
        // Computing the fees based on the spread
        feeBurn = _piecewiseLinear(spread, col.feeData.xFeeBurn, col.feeData.yFeeBurn);
        // Fees could in some occasions depend on other factors like collateral ratio
        // Keepers are the ones updating this part of the fees
        feeBurn = (feeBurn * col.feeData.bonusMalusBurn) / BASE;
    }

    /// @notice Computes the spread for a given collateral and for a given amount of collateral from users to cover
    /// @param newColFromUsers Value of the collateral from users to cover
    /// @param col Struct for the collateral of interest
    /// @return The spread that is the ratio between what's to cover minus
    /// what's covered by HAs divided what's to cover
    /// @dev This function is typically called to compute mint or burn fees
    /// @dev It seeks from the `PerpetualManager` contract associated to the collateral the total amount
    /// already covered by HAs and compares it to the amount to cover
    function _computeSpread(uint256 newColFromUsers, Collateral storage col) internal view returns (uint256) {
        (uint256 maxALock, uint256 totalCoveredAmount) = col.perpetualManager.getCoverageInfo();
        uint256 colFromUsersToCover = (newColFromUsers * maxALock) / BASE;
        uint256 spread = 0;
        if (colFromUsersToCover > totalCoveredAmount) {
            spread = ((colFromUsersToCover - totalCoveredAmount) * BASE) / colFromUsersToCover;
        }
        return spread;
    }
}
