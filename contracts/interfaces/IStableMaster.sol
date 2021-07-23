// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Normally just importing `IPoolManager` should be sufficient, but for clarity here
// we prefer to import all concerned interfaces
import "./IPoolManager.sol";
import "./IOracle.sol";
import "./IPerpetualManager.sol";
import "./ISanToken.sol";

// Struct to handle all the parameters to manage the fees
// related to a given collateral pool (associated to the stablecoin)
struct CollateralFees {
    // Values of the thresholds to compute the minting fees
    // depending on HA coverage (scaled by `BASE`)
    uint256[] xFeeMint;
    // Values of the fees at thresholds (scaled by `BASE`)
    uint256[] yFeeMint;
    // Minting fees correction set by the `FeeManager` contract: they are going to be multiplied
    // to the value of the fees computed using the coverage curve
    uint256 bonusMalusMint;
    // Values of the thresholds to compute the burning fees
    // depending on HA coverage (scaled by `BASE`)
    uint256[] xFeeBurn;
    // Values of the fees at thresholds (scaled by `BASE`)
    uint256[] yFeeBurn;
    // Burning fees set by the `FeeManager` contract: they are going to be multiplied
    // to the value of the fees computed using the coverage curve
    uint256 bonusMalusBurn;
}

// Struct to handle all the variables and parameters to handle SLPs in the protocol
// including the fraction of interests they receive or the fees to be distributed to
// them
struct SLPData {
    // Last timestamp at which the `sanRate` has been updated for SLPs
    uint256 lastBlockUpdated;
    // Fees accumulated from previous blocks and to be distributed to SLPs
    uint256 lockedInterests;
    // Max update of the `sanRate` in a single block
    uint256 maxSanRateUpdate;
    // Slippage factor that's applied to SLPs exiting (depends on collateral ratio)
    // If `slippage = BASE`, SLPs can get nothing, if `slippage = 0` they get their full claim
    // Updated by keepers and scaled by base
    uint256 slippage;
    // Part of the fees normally going to SLPs that is left aside
    // before the protocol is collateralized back again (depends on collateral ratio)
    // Updated by keepers
    uint256 slippageFee;
    // Amount of fees left aside for SLPs and that will be distributed
    // when the protocol is collateralized back again
    uint256 feesAside;
    // Portion of the fees from users minting and burning
    // that goes to SLPs (the rest goes to surplus)
    uint256 feesForSLPs;
    // Portion of the interests from lending
    // that goes to SLPs (the rest goes to surplus)
    uint256 interestsForSLPs;
}

/// @title IStableMasterFunctions
/// @author Angle Core Team
/// @notice Interface for the `StableMaster` contract
interface IStableMasterFunctions {
    function deploy(
        address[] memory _governorList,
        address _guardian,
        address _agToken
    ) external;

    // ============================== Lending ======================================

    function accumulateInterest(uint256 gain) external;

    function signalLoss(uint256 loss) external;

    // ============================== HAs ==========================================

    function getIssuanceInfo() external view returns (int256, uint256);

    function updateStocksUsers(int256 amount) external;

    function convertToSLP(uint256 amount, address user) external;

    // ============================== Keepers ======================================

    function getCollateralRatio() external returns (uint256);

    function setFeeKeeper(
        uint256 feeMint,
        uint256 feeBurn,
        uint256 _slippage,
        uint256 _slippageFee
    ) external;

    // ============================= Governance ====================================

    function addGovernor(address _governor) external;

    function removeGovernor(address _governor) external;

    function setGuardian(address newGuardian, address oldGuardian) external;

    function revokeGuardian(address oldGuardian) external;
}

/// @title IStableMaster
/// @author Angle Core Team
/// @notice Previous interace with additionnal getters for public variables and mappings
interface IStableMaster is IStableMasterFunctions {
    function agToken() external view returns (address);

    function collateralMap(IPoolManager poolManager)
        external
        view
        returns (
            IERC20 token,
            ISanToken sanToken,
            IPerpetualManager perpetualManager,
            IOracle oracle,
            int256 stocksUsers,
            uint256 sanRate,
            SLPData memory slpData,
            CollateralFees memory feeData
        );
}
