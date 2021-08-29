// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "./StrategyEvents.sol";

/// @title Strategy
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat
/// @notice A lender optimisation strategy for any ERC20 asset
/// @dev This strategy works by taking plugins designed for standard lending platforms
/// It automatically chooses the best yield generating platform and adjusts accordingly
/// The adjustment is sub optimal so there is an additional option to manually set position
contract Strategy is StrategyEvents, BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // ======================== References to contracts ============================

    IGenericLender[] public lenders;

    /// @notice Oracle to give the rate feed, that is the price of the collateral
    /// with respect to the price of the stablecoin
    /// This reference can be changed
    IOracle public oracle;

    // ======================== Parameters =========================================

    uint256 public withdrawalThreshold = 1e14;

    // ============================== Constructor ==================================

    /// @notice Constructor of the `Strategy`
    /// @param _poolManager Address of the `PoolManager` lending to this strategy
    /// @param _rewards  The token given to reward keepers.
    /// @param _oracle Oracle to compute conversion from ethToWant
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    constructor(
        address _poolManager,
        IERC20 _rewards,
        IOracle _oracle,
        address[] memory governorList,
        address guardian
    ) BaseStrategy(_poolManager, _rewards, governorList, guardian) {
        require(
            guardian != address(0) && address(_oracle) != address(0) && address(_rewards) != address(0),
            "zero address"
        );
        oracle = _oracle;
    }

    // ========================== Internal Mechanics ===============================

    /// @notice Frees up profit plus `_debtOutstanding`.
    /// @param _debtOutstanding Amount to withdraw
    /// @return _profit Profit freed by the call
    /// @return _loss Loss discovered by the call
    /// @return _debtPayment Amount freed to reimburse the debt
    /// @dev If `_debtOutstanding` is more than we can free we get as much as possible.
    function _prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = 0;
        _loss = 0; //for clarity
        _debtPayment = _debtOutstanding;

        uint256 lentAssets = lentTotalAssets();

        uint256 looseAssets = want.balanceOf(address(this));

        uint256 total = looseAssets + lentAssets;

        if (lentAssets == 0) {
            // No position to harvest or profit to report
            if (_debtPayment > looseAssets) {
                // We can only return looseAssets
                _debtPayment = looseAssets;
            }

            return (_profit, _loss, _debtPayment);
        }

        uint256 debt = poolManager.strategies(address(this)).totalStrategyDebt;

        if (total > debt) {
            _profit = total - debt;

            uint256 amountToFree = _profit + _debtPayment;
            // We need to add outstanding to our profit
            // don't need to do logic if there is nothing to free
            if (amountToFree > 0 && looseAssets < amountToFree) {
                // Withdraw what we can withdraw
                _withdrawSome(amountToFree - looseAssets);
                uint256 newLoose = want.balanceOf(address(this));

                // If we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _profit, _debtPayment);
                    }
                }
            }
        } else {
            // Serious loss should never happen but if it does lets record it accurately
            _loss = debt - total;

            uint256 amountToFree = _loss + _debtPayment;
            if (amountToFree > 0 && looseAssets < amountToFree) {
                // Withdraw what we can withdraw

                _withdrawSome(amountToFree - looseAssets);
                uint256 newLoose = want.balanceOf(address(this));

                // If we dont have enough money adjust `_debtOutstanding` and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_loss > newLoose) {
                        _loss = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _loss, _debtPayment);
                    }
                }
            }
        }
    }

    /// @notice Estimates highest and lowest apr lenders.
    /// @return _lowest The index of the lender with lowest apr
    /// @return _lowestApr The lowest apr
    /// @return _highest The index of the lender with highest apr
    /// @return _potential The potential apr of this lender if funds are moved from lowest to highest
    function _estimateAdjustPosition()
        internal
        view
        returns (
            uint256 _lowest,
            uint256 _lowestApr,
            uint256 _highest,
            uint256 _potential
        )
    {
        //all loose assets are to be invested
        uint256 looseAssets = want.balanceOf(address(this));

        // our simple algo
        // get the lowest apr strat
        // cycle through and see who could take its funds plus want for the highest apr
        _lowestApr = type(uint256).max;
        _lowest = 0;
        uint256 lowestNav = 0;
        for (uint256 i = 0; i < lenders.length; i++) {
            if (lenders[i].hasAssets()) {
                uint256 apr = lenders[i].apr();
                if (apr < _lowestApr) {
                    _lowestApr = apr;
                    _lowest = i;
                    lowestNav = lenders[i].nav();
                }
            }
        }

        uint256 toAdd = lowestNav + looseAssets;

        uint256 highestApr = 0;
        _highest = 0;

        for (uint256 i = 0; i < lenders.length; i++) {
            uint256 apr;
            apr = lenders[i].aprAfterDeposit(looseAssets);

            if (apr > highestApr) {
                highestApr = apr;
                _highest = i;
            }
        }

        //if we can improve apr by withdrawing we do so
        _potential = lenders[_highest].aprAfterDeposit(toAdd);
    }

    /// @notice Function called by keepers to adjust the position
    /// @dev The algorithm moves assets from lowest return to highest
    /// like a very slow idiot bubble sort
    function _adjustPosition() internal override {
        // Emergency exit is dealt with at beginning of harvest
        if (emergencyExit) {
            return;
        }

        // We just keep all money in want if we dont have any lenders
        if (lenders.length == 0) {
            return;
        }

        (uint256 lowest, uint256 lowestApr, uint256 highest, uint256 potential) = _estimateAdjustPosition();

        if (potential > lowestApr) {
            // Apr should go down after deposit so wont be withdrawing from self
            lenders[lowest].withdrawAll();
        }

        uint256 bal = want.balanceOf(address(this));
        if (bal > 0) {
            want.safeTransfer(address(lenders[highest]), bal);
            lenders[highest].deposit();
        }
    }

    /// @notice Withdraws a given amount from lenders
    /// @param _amount The amount to withdraw
    /// @dev Cycle through withdrawing from worst rate first
    function _withdrawSome(uint256 _amount) internal returns (uint256 amountWithdrawn) {
        if (lenders.length == 0) {
            return 0;
        }

        // Don't withdraw dust
        if (_amount < withdrawalThreshold) {
            return 0;
        }

        amountWithdrawn = 0;
        // In Most situations this will only run once. Only big withdrawals will be a gas guzzler
        uint256 j = 0;
        while (amountWithdrawn < _amount) {
            uint256 lowestApr = type(uint256).max;
            uint256 lowest = 0;
            for (uint256 i = 0; i < lenders.length; i++) {
                if (lenders[i].hasAssets()) {
                    uint256 apr = lenders[i].apr();
                    if (apr < lowestApr) {
                        lowestApr = apr;
                        lowest = i;
                    }
                }
            }
            if (!lenders[lowest].hasAssets()) {
                return amountWithdrawn;
            }
            amountWithdrawn = amountWithdrawn + lenders[lowest].withdraw(_amount - amountWithdrawn);
            j++;
            // To avoid want infinite loop
            if (j >= 6) {
                return amountWithdrawn;
            }
        }
    }

    /// @notice Liquidates up to `_amountNeeded` of `want` of this strategy's positions,
    /// irregardless of slippage. Any excess will be re-invested with `_adjustPosition()`.
    /// This function should return the amount of `want` tokens made available by the
    /// liquidation. If there is a difference between them, `_loss` indicates whether the
    /// difference is due to a realized loss, or if there is some other sitution at play
    /// (e.g. locked funds) where the amount made available is less than what is needed.
    ///
    /// NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    function _liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
        uint256 _balance = want.balanceOf(address(this));

        if (_balance >= _amountNeeded) {
            //if we don't set reserve here withdrawer will be sent our full balance
            return (_amountNeeded, 0);
        } else {
            uint256 received = _withdrawSome(_amountNeeded - _balance) + (_balance);
            if (received >= _amountNeeded) {
                return (_amountNeeded, 0);
            } else {
                return (received, 0);
            }
        }
    }

    /// @notice Liquidates everything and returns the amount that got freed.
    /// This function is used during emergency exit instead of `_prepareReturn()` to
    /// liquidate all of the Strategy's positions back to the Manager.
    function _liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = _liquidatePosition(estimatedTotalAssets());
    }

    // ========================== View Functions ===================================

    struct LendStatus {
        string name;
        uint256 assets;
        uint256 rate;
        address add;
    }

    /// @notice View function to check the current state of the strategy
    /// @return Returns the status of all lenders attached the strategy
    function lendStatuses() external view returns (LendStatus[] memory) {
        LendStatus[] memory statuses = new LendStatus[](lenders.length);
        for (uint256 i = 0; i < lenders.length; i++) {
            LendStatus memory s;
            s.name = lenders[i].lenderName();
            s.add = address(lenders[i]);
            s.assets = lenders[i].nav();
            s.rate = lenders[i].apr();
            statuses[i] = s;
        }

        return statuses;
    }

    /// @notice View function to check the total assets lent
    function lentTotalAssets() public view returns (uint256) {
        uint256 nav = 0;
        for (uint256 i = 0; i < lenders.length; i++) {
            nav = nav + lenders[i].nav();
        }
        return nav;
    }

    /// @notice View function to check the total assets managed by the strategy
    function estimatedTotalAssets() public view override returns (uint256 nav) {
        nav = lentTotalAssets() + want.balanceOf(address(this));
    }

    /// @notice View function to check the number of lending platforms
    function numLenders() external view returns (uint256) {
        return lenders.length;
    }

    /// @notice The weighted apr of all lenders. sum(nav * apr)/totalNav
    function estimatedAPR() external view returns (uint256) {
        uint256 bal = estimatedTotalAssets();
        if (bal == 0) {
            return 0;
        }

        uint256 weightedAPR = 0;

        for (uint256 i = 0; i < lenders.length; i++) {
            weightedAPR = weightedAPR + lenders[i].weightedApr();
        }

        return weightedAPR / bal;
    }

    /// @notice Does the oracle (Uniswap - Chainlink for now) conversion from wETH to want
    function ethToWant(uint256 _amount) public view override returns (uint256) {
        return (oracle.readQuote(_amount) * wantBase) / BASE;
    }

    /// @notice Prevents the governance from withdrawing want tokens
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }

    // ============================ Governance =====================================

    struct LenderRatio {
        address lender;
        //share x 1000
        uint16 share;
    }

    /// @notice Reallocates all funds according to a new distributions
    /// @param _newPositions List of shares to specify the new allocation
    /// @dev Share must add up to 1000. 500 means 50% etc
    /// @dev This code has been forked, so we have not thoroughly tested it on our own
    function manualAllocation(LenderRatio[] memory _newPositions) external onlyRole(GUARDIAN_ROLE) {
        uint256 share = 0;

        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].withdrawAll();
        }

        uint256 assets = want.balanceOf(address(this));

        for (uint256 i = 0; i < _newPositions.length; i++) {
            bool found = false;

            //might be annoying and expensive to do this second loop but worth it for safety
            for (uint256 j = 0; j < lenders.length; j++) {
                if (address(lenders[j]) == _newPositions[i].lender) {
                    found = true;
                }
            }
            require(found, "invalid lender");

            share = share + _newPositions[i].share;
            uint256 toSend = (assets * _newPositions[i].share) / 1000;
            want.safeTransfer(_newPositions[i].lender, toSend);
            IGenericLender(_newPositions[i].lender).deposit();
        }

        require(share == 1000, "invalid shares");
    }

    /// @notice Changes the withdrawal threshold
    /// @param _threshold The new withdrawal threshold
    /// @dev governor, guardian or `PoolManager` only
    function setWithdrawalThreshold(uint256 _threshold) external onlyRole(GUARDIAN_ROLE) {
        withdrawalThreshold = _threshold;
    }

    /// @notice Changes the oracle contract used to compute collateral price with respect to the stablecoin's price
    /// @param _oracle Oracle contract
    /// @dev The collateral `PoolManager` does not store a reference to an oracle, the value of the oracle can directly
    /// be set by the `StableMaster`
    /// @dev The `outbase` of the new oracle should be the same as the `wantBase`
    function setOracle(IOracle _oracle) external onlyRole(GUARDIAN_ROLE) {
        oracle = _oracle;
    }

    /// @notice Add lenders for the strategy to choose between
    /// @param newLender The adapter to the added lending platform
    /// @dev Governor, guardian or `PoolManager` only
    function addLender(IGenericLender newLender) external onlyRole(GUARDIAN_ROLE) {
        require(newLender.strategy() == address(this), "undocked lender");

        for (uint256 i = 0; i < lenders.length; i++) {
            require(address(newLender) != address(lenders[i]), "already added");
        }
        lenders.push(newLender);

        emit AddLender(address(newLender));
    }

    /// @notice Removes a lending platform and fails if total withdrawal is impossible
    /// @param lender The address of the adapter to the lending platform to remove
    function safeRemoveLender(address lender) external onlyRole(GUARDIAN_ROLE) {
        _removeLender(lender, false);
    }

    /// @notice Removes a lending platform and even if total withdrawal is impossible
    /// @param lender The address of the adapter to the lending platform to remove
    function forceRemoveLender(address lender) external onlyRole(GUARDIAN_ROLE) {
        _removeLender(lender, true);
    }

    /// @notice Internal function to handle lending platform removing
    /// @param lender The address of the adapter for the lending platform to remove
    /// @param force Whether it is required that all the funds are withdrawn prior to removal
    function _removeLender(address lender, bool force) internal {
        for (uint256 i = 0; i < lenders.length; i++) {
            if (lender == address(lenders[i])) {
                bool allWithdrawn = lenders[i].withdrawAll();

                if (!force) {
                    require(allWithdrawn, "withdrawal failed");
                }

                // Put the last index here
                // then remove last index
                if (i != lenders.length - 1) {
                    lenders[i] = lenders[lenders.length - 1];
                }

                // Pop shortens array by 1 thereby deleting the last index
                lenders.pop();

                // If balance to spend we might as well put it into the best lender
                if (want.balanceOf(address(this)) > 0) {
                    _adjustPosition();
                }

                emit RemoveLender(lender);

                return;
            }
        }
        require(false, "invalid lender");
    }

    // ========================== Manager functions ================================

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    /// @dev This internal function has to be put in this file because `AccessControl` is not defined
    /// in `PoolManagerInternal`
    function addGuardian(address _guardian) external override onlyRole(POOLMANAGER_ROLE) {
        // Granting the new role
        // Access control for this contract
        grantRole(GUARDIAN_ROLE, _guardian);
        // Propagating the new role in other contract
        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].grantRole(GUARDIAN_ROLE, _guardian);
        }
    }

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function revokeGuardian(address guardian) external override onlyRole(POOLMANAGER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, guardian);
        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].revokeRole(GUARDIAN_ROLE, guardian);
        }
    }
}
