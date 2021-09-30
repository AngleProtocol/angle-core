// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./OracleAbstract.sol";

import "./modules/ModuleChainlinkMulti.sol";
import "./modules/ModuleUniswapMulti.sol";

/// @title OracleMulti
/// @author Angle Core Team
/// @notice Oracle contract, one contract is deployed per collateral/stablecoin pair
/// @dev This contract concerns an oracle that only uses both Chainlink and Uniswap for multiple pools
/// @dev This is going to be used for like ETH/EUR oracles
/// @dev Like all oracle contracts, this contract is an instance of `OracleAstract` that contains some
/// base functions
contract OracleMulti is OracleAbstract, ModuleChainlinkMulti, ModuleUniswapMulti {
    /// @notice Whether the final rate obtained with Uniswap should be multiplied to last rate from Chainlink
    uint8 public immutable uniFinalCurrency;

    /// @notice Unit out Uniswap currency
    uint256 public immutable outBase;

    /// @notice Constructor for an oracle using both Uniswap and Chainlink with multiple pools to read from
    /// @param addressInAndOutUni List of 2 addresses representing the in-currency address and the out-currency address
    /// @param _circuitUniswap Path of the Uniswap pools
    /// @param _circuitUniIsMultiplied Whether we should multiply or divide by this rate in the path
    /// @param _twapPeriod Time weighted average window for all Uniswap pools
    /// @param observationLength Number of observations that each pool should have stored
    /// @param _uniFinalCurrency Whether we need to use the last Chainlink oracle to convert to another
    /// currency / asset (Forex for instance)
    /// @param _circuitChainlink Chainlink pool addresses put in order
    /// @param _circuitChainIsMultiplied Whether we should multiply or divide by this rate
    /// @param guardians List of governor or guardian addresses
    /// @param _description Description of the assets concerned by the oracle
    /// @dev When deploying this contract, it is important to check in the case where Uniswap circuit is not final whether
    /// Chainlink and Uniswap circuits are compatible. If Chainlink is UNI-WBTC and WBTC-USD and Uniswap is just UNI-WETH,
    /// then Chainlink cannot be the final circuit
    constructor(
        address[] memory addressInAndOutUni,
        IUniswapV3Pool[] memory _circuitUniswap,
        uint8[] memory _circuitUniIsMultiplied,
        uint32 _twapPeriod,
        uint16 observationLength,
        uint8 _uniFinalCurrency,
        address[] memory _circuitChainlink,
        uint8[] memory _circuitChainIsMultiplied,
        address[] memory guardians,
        bytes32 _description
    )
        ModuleUniswapMulti(_circuitUniswap, _circuitUniIsMultiplied, _twapPeriod, observationLength, guardians)
        ModuleChainlinkMulti(_circuitChainlink, _circuitChainIsMultiplied)
    {
        require(addressInAndOutUni.length == 2, "107");
        // Using the tokens' metadata to get the in and out currencies decimals
        IERC20Metadata inCur = IERC20Metadata(addressInAndOutUni[0]);
        IERC20Metadata outCur = IERC20Metadata(addressInAndOutUni[1]);
        inBase = 10**(inCur.decimals());
        outBase = 10**(outCur.decimals());

        uniFinalCurrency = _uniFinalCurrency;
        description = _description;
    }

    /// @notice Reads the Uniswap rate using the circuit given
    /// @return The current rate between the in-currency and out-currency
    /// @dev By default even if there is a Chainlink rate, this function returns the Uniswap rate
    /// @dev The amount returned is expressed with base `BASE` (and not the base of the out-currency)
    function read() external view override returns (uint256) {
        return _readUniswapQuote(inBase);
    }

    /// @notice Converts an in-currency quote amount to out-currency using the Uniswap rate
    /// @param quoteAmount Amount (in the input collateral) to be converted in out-currency
    /// @return Quote amount in out-currency from the base amount in in-currency
    /// @dev Like in the `read` function, this function returns the Uniswap quote
    /// @dev The amount returned is expressed with base `BASE` (and not the base of the out-currency)
    function readQuote(uint256 quoteAmount) external view override returns (uint256) {
        return _readUniswapQuote(quoteAmount);
    }

    /// @notice Returns Uniswap and Chainlink values (with the first one being the smallest one)
    /// @param quoteAmount Amount expressed in the in-currency base.
    /// @dev If quoteAmount is `inBase`, rates are returned
    /// @return The first parameter is the lowest value and the second parameter is the highest
    /// @dev The amount returned is expressed with base `BASE` (and not the base of the out-currency)
    function _readAll(uint256 quoteAmount) internal view override returns (uint256, uint256) {
        uint256 quoteAmountUni = _quoteUniswap(quoteAmount);

        // The current uni rate is in `outBase` we want our rate to all be in base `BASE`
        quoteAmountUni = (quoteAmountUni * BASE) / outBase;
        // The current amount is in `inBase` we want our rate to all be in base `BASE`
        uint256 quoteAmountCL = (quoteAmount * BASE) / inBase;
        uint256 ratio;

        (quoteAmountCL, ratio) = _quoteChainlink(quoteAmountCL);

        if (uniFinalCurrency > 0) {
            quoteAmountUni = _changeUniswapNotFinal(ratio, quoteAmountUni);
        }

        if (quoteAmountCL <= quoteAmountUni) {
            return (quoteAmountCL, quoteAmountUni);
        } else return (quoteAmountUni, quoteAmountCL);
    }

    /// @notice Uses Chainlink's value to change Uniswap's rate
    /// @param ratio Value of the last oracle rate of Chainlink
    /// @param quoteAmountUni End quote computed from Uniswap's circuit
    /// @dev We use the last Chainlink rate to correct the value obtained with Uniswap. It may for instance be used
    /// to get a Uniswap price in EUR (ex: ETH -> USDC and we use this to do USDC -> EUR)
    function _changeUniswapNotFinal(uint256 ratio, uint256 quoteAmountUni) internal view returns (uint256) {
        uint256 idxLastPoolCL = circuitChainlink.length - 1;
        (quoteAmountUni, ) = _readChainlinkFeed(
            quoteAmountUni,
            circuitChainlink[idxLastPoolCL],
            circuitChainIsMultiplied[idxLastPoolCL],
            chainlinkDecimals[idxLastPoolCL],
            ratio
        );
        return quoteAmountUni;
    }

    /// @notice Internal function to convert an in-currency quote amount to out-currency using only the Uniswap rate
    /// and by correcting it if needed from Chainlink last rate
    /// @param quoteAmount Amount (in the input collateral) to be converted in out-currency using Uniswap (and Chainlink)
    /// at the end of the funnel
    /// @return uniAmount Quote amount in out-currency from the base amount in in-currency
    /// @dev The amount returned is expressed with base `BASE` (and not the base of the out-currency)
    function _readUniswapQuote(uint256 quoteAmount) internal view returns (uint256 uniAmount) {
        uniAmount = _quoteUniswap(quoteAmount);
        // The current uni rate is in outBase we want our rate to all be in base
        uniAmount = (uniAmount * BASE) / outBase;
        if (uniFinalCurrency > 0) {
            uniAmount = _changeUniswapNotFinal(0, uniAmount);
        }
    }
}
