// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

/// @title FunctionUtils
/// @author Angle Core Team
/// @notice Contains all the utility functions that are needed in different places of the protocol
/// @dev Functions in this contract should typically be pure functions
/// @dev This contract is voluntarily a contract and not a library to save some gas cost every time it is used
contract FunctionUtils {
    /// @notice Base that is used to compute ratios and floating numbers
    uint256 public constant BASE_TOKENS = 10**18;
    /// @notice Base that is used to define parameters that need to have a floating value (for instance parameters
    /// that are defined as ratios)
    uint256 public constant BASE_PARAMS = 10**9;

    /// @notice Computes the value of a linear by part function at a given point
    /// @param x Point of the function we want to compute
    /// @param xArray List of breaking points (in ascending order) that define the linear by part function
    /// @param yArray List of values at breaking points (not necessarily in ascending order)
    /// @dev The evolution of the linear by part function between two breaking points is linear
    /// @dev Before the first breaking point and after the last one, the function is constant with a value
    /// equal to the first or last value of the yArray
    /// @dev This function is relevant if `x` is between O and `BASE_PARAMS`. If `x` is greater than that, then
    /// everything will be as if `x` is equal to the greater element of the `xArray`
    function _piecewiseLinear(
        uint64 x,
        uint64[] memory xArray,
        uint64[] memory yArray
    ) internal pure returns (uint64) {
        if (x >= xArray[xArray.length - 1]) {
            return yArray[xArray.length - 1];
        } else if (x <= xArray[0]) {
            return yArray[0];
        } else {
            uint256 lower;
            uint256 upper = xArray.length - 1;
            uint256 mid;
            while (upper - lower > 1) {
                mid = lower + (upper - lower) / 2;
                if (xArray[mid] <= x) {
                    lower = mid;
                } else {
                    upper = mid;
                }
            }
            if (yArray[upper] > yArray[lower]) {
                // There is no risk of overflow here as in the product of the difference of `y`
                // with the difference of `x`, the product is inferior to `BASE_PARAMS**2` which does not
                // overflow for `uint64`
                return
                    yArray[lower] +
                    ((yArray[upper] - yArray[lower]) * (x - xArray[lower])) /
                    (xArray[upper] - xArray[lower]);
            } else {
                return
                    yArray[lower] -
                    ((yArray[lower] - yArray[upper]) * (x - xArray[lower])) /
                    (xArray[upper] - xArray[lower]);
            }
        }
    }

    /// @notice Checks if the input arrays given by governance to update the fee structure is valid
    /// @param xArray List of breaking points (in ascending order) that define the linear by part function
    /// @param yArray List of values at breaking points (not necessarily in ascending order)
    /// @dev This function is a way to avoid some governance attacks or errors
    /// @dev The modifier checks if the arrays have a non null length, if their length is the same, if the values
    /// in the `xArray` are in ascending order and if the values in the `xArray` and in the `yArray` are not superior
    /// to `BASE_PARAMS`
    modifier onlyCompatibleInputArrays(uint64[] memory xArray, uint64[] memory yArray) {
        require(xArray.length == yArray.length && xArray.length > 0, "5");
        for (uint256 i = 0; i <= yArray.length - 1; i++) {
            require(yArray[i] <= uint64(BASE_PARAMS) && xArray[i] <= uint64(BASE_PARAMS), "6");
            if (i > 0) {
                require(xArray[i] > xArray[i - 1], "7");
            }
        }
        _;
    }

    /// @notice Checks if the new value given for the parameter is consistent (it should be inferior to 1
    /// if it corresponds to a ratio)
    /// @param fees Value of the new parameter to check
    modifier onlyCompatibleFees(uint64 fees) {
        require(fees <= BASE_PARAMS, "4");
        _;
    }

    /// @notice Checks if the new address given is not null
    /// @param newAddress Address to check
    /// @dev Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-zero-address-validation
    modifier zeroCheck(address newAddress) {
        require(newAddress != address(0), "0");
        _;
    }
}
