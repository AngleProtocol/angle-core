// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./FeeManagerEvents.sol";

/// @title FeeManagerStorage
/// @author Angle Core Team
/// @dev `FeeManagerStorage` contains all the parameters (most often fee parameters) to add corrections
/// to fees in the `StableMaster` and `PerpetualManager` contracts
contract FeeManagerStorage is FeeManagerEvents, FunctionUtils {
    // ==================== References to other contracts ==========================

    /// @notice Address of the `StableMaster` contract corresponding to this contract
    /// This reference cannot be modified
    IStableMaster public stableMaster;

    /// @notice Address of the `PerpetualManager` corresponding to this contract
    /// This reference cannot be modified
    IPerpetualManager public perpetualManager;

    // ================= Parameters that can be set by governance ==================

    /// @notice Bonus - Malus Fee, means that if the `fee > BASE` then agents incur a malus and will
    /// have larger fees, while `fee < BASE` they incur a smaller fee than what they would have if fees
    /// just consisted in what was obtained using coverage
    /// @notice Values of the collateral ratio where mint transaction fees will change for users
    /// It should be ranked in ascending order
    uint256[] public xBonusMalusMint = [(5 * BASE) / 10, BASE];
    /// @notice Values of the mint fees at the points of collateral ratio in the array above
    /// The evolution of the fees when collateral ratio is between two threshold values is linear
    uint256[] public yBonusMalusMint = [(8 * BASE) / 10, BASE];
    /// @notice Values of the collateral ratio where burn transaction fees will change
    uint256[] public xBonusMalusBurn = [0, (5 * BASE) / 10, BASE, (13 * BASE) / 10, (15 * BASE) / 10];
    /// @notice Values of the burn fees at the points of collateral ratio in the array above
    uint256[] public yBonusMalusBurn = [BASE * 10, BASE * 4, (15 * BASE) / 10, BASE, BASE];

    /// @notice Values of the collateral ratio where the slippage factor for SLPs exiting will evolve
    uint256[] public xSlippage = [(5 * BASE) / 10, BASE, (12 * BASE) / 10, (15 * BASE) / 10];
    /// @notice Slippage factor at the values of collateral ratio above
    uint256[] public ySlippage = [BASE / 2, BASE / 5, BASE / 10, 0];
    /// @notice Values of the collateral ratio where the slippage fee, that is the portion of the fees
    /// that does not come to SLPs although changes
    uint256[] public xSlippageFee = [(5 * BASE) / 10, BASE, (12 * BASE) / 10, (15 * BASE) / 10];
    /// @notice Slippage fee value at the values of collateral ratio above
    uint256[] public ySlippageFee = [(3 * BASE) / 4, BASE / 2, (15 * BASE) / 100, 0];

    /// @notice Bonus - Malus HA deposit Fee, means that if the `fee > BASE` then HAs incur a malus and
    /// will have larger fees, while `fee < BASE` they incur a smaller fee than what they would have if
    /// fees just consisted in what was obtained using coverage
    uint256 public haFeeDeposit = BASE;
    /// @notice Bonus - Malus HA withdraw Fee,
    uint256 public haFeeWithdraw = BASE;
}
