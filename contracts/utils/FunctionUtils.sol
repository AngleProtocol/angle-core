// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

/// @title FunctionUtils
/// @author Angle Core Team
/// @notice Contains all the utility functions that are needed in different places of the protocol
/// @dev Functions in this contract should typically be pure functions
/// @dev This contract is voluntarily a contract and not a library to save some gas cost every time it is used
abstract contract FunctionUtils {
    /// @notice Base that is used to compute ratios and floating numbers across all contracts of the protocol
    uint256 public constant BASE = 10**18;

    /// @notice Computes the value of a linear by part function at a given point
    /// @param x Point of the function we want to compute
    /// @param xArray List of breaking points (in ascending order) that define the linear by part function
    /// @param yArray List of values at breaking points (not necessarily in ascending order)
    /// @dev The evolution of the linear by part function between two breaking points is linear
    /// @dev Before the first breaking point and after the last one, the function is constant with a value
    /// equal to the first or last value of the yArray
    function _piecewiseLinear(
        uint256 x,
        uint256[] memory xArray,
        uint256[] memory yArray
    ) internal pure returns (uint256 y) {
        if (x >= xArray[xArray.length - 1]) {
            return yArray[xArray.length - 1];
        } else if (x <= xArray[0]) {
            return yArray[0];
        } else {
            for (uint256 i = xArray.length - 2; i >= 0; i--) {
                if (x > xArray[i]) {
                    if (yArray[i + 1] > yArray[i]) {
                        return
                            yArray[i] + ((yArray[i + 1] - yArray[i]) * (x - xArray[i])) / (xArray[i + 1] - xArray[i]);
                    } else {
                        return
                            yArray[i] - ((yArray[i] - yArray[i + 1]) * (x - xArray[i])) / (xArray[i + 1] - xArray[i]);
                    }
                }
            }
        }
    }

    /// @notice Checks if the input arrays given by governance to update the fee structure is valid
    /// @param xArray List of breaking points (in ascending order) that define the linear by part function
    /// @param yArray List of values at breaking points (not necessarily in ascending order)
    /// @param ySmallerThanBase If the values of `yArray` have to be smaller than `BASE`
    /// @dev This function is a way to avoid some governance attacks or errors
    /// @dev The modifier checks if the arrays have the same length, if the values in the xArray are in ascending order
    /// and if the values in the `yArray` are not superior to `BASE` (in case of)
    modifier onlyCompatibleInputArrays(
        uint256[] memory xArray,
        uint256[] memory yArray,
        bool ySmallerThanBase
    ) {
        require(xArray.length == yArray.length, "incorrect array length");
        for (uint256 i = 0; i <= yArray.length - 1; i++) {
            if (ySmallerThanBase) require(yArray[i] <= BASE, "incorrect y array values");
            if (i > 0) {
                require(xArray[i] > xArray[i - 1], "incorrect x array values");
            }
        }
        _;
    }

    /// @notice Checks if the new value given for the parameter is consistent (it should be inferior to 1
    /// if it corresponds to a ratio)
    /// @param fees Value of the new parameter to check
    modifier onlyCompatibleFees(uint256 fees) {
        require(fees <= BASE, "incorrect value");
        _;
    }

    /// @notice Checks if the new address given is not null
    /// @param newAddress Address to check
    /// @dev Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-zero-address-validation
    modifier zeroCheck(address newAddress) {
        require(newAddress != address(0), "zero address");
        _;
    }
}
