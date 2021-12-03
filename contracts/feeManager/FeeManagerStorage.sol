// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./FeeManagerEvents.sol";

/// @title FeeManagerStorage
/// @author Angle Core Team
/// @dev `FeeManagerStorage` contains all the parameters (most often fee parameters) to add corrections
/// to fees in the `StableMaster` and `PerpetualManager` contracts
contract FeeManagerStorage is FeeManagerEvents {
    uint64 public constant BASE_PARAMS_CASTED = 10**9;
    // ==================== References to other contracts ==========================

    /// @notice Address of the `StableMaster` contract corresponding to this contract
    /// This reference cannot be modified
    IStableMaster public stableMaster;

    /// @notice Address of the `PerpetualManager` corresponding to this contract
    /// This reference cannot be modified
    IPerpetualManager public perpetualManager;

    // ================= Parameters that can be set by governance ==================

    /// @notice Bonus - Malus Fee, means that if the `fee > BASE_PARAMS` then agents incur a malus and will
    /// have larger fees, while `fee < BASE_PARAMS` they incur a smaller fee than what they would have if fees
    /// just consisted in what was obtained using the hedge ratio
    /// @notice Values of the collateral ratio where mint transaction fees will change for users
    /// It should be ranked in ascending order
    uint256[] public xBonusMalusMint;
    /// @notice Values of the bonus/malus on the mint fees at the points of collateral ratio in the array above
    /// The evolution of the fees when collateral ratio is between two threshold values is linear
    uint64[] public yBonusMalusMint;
    /// @notice Values of the collateral ratio where burn transaction fees will change
    uint256[] public xBonusMalusBurn;
    /// @notice Values of the bonus/malus on the burn fees at the points of collateral ratio in the array above
    uint64[] public yBonusMalusBurn;

    /// @notice Values of the collateral ratio where the slippage factor for SLPs exiting will evolve
    uint256[] public xSlippage;
    /// @notice Slippage factor at the values of collateral ratio above
    uint64[] public ySlippage;
    /// @notice Values of the collateral ratio where the slippage fee, that is the portion of the fees
    /// that does not come to SLPs although changes
    uint256[] public xSlippageFee;
    /// @notice Slippage fee value at the values of collateral ratio above
    uint64[] public ySlippageFee;

    /// @notice Bonus - Malus HA deposit Fee, means that if the `fee > BASE_PARAMS` then HAs incur a malus and
    /// will have larger fees, while `fee < BASE_PARAMS` they incur a smaller fee than what they would have if
    /// fees just consisted in what was obtained using hedge ratio
    uint64 public haFeeDeposit;
    /// @notice Bonus - Malus HA withdraw Fee
    uint64 public haFeeWithdraw;
}
