// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./BondingCurveEvents.sol";

/// @title BondingCurve
/// @author Angle Core Team
/// @notice Enables anyone to buy ANGLE governance token or any type of token following a bonding
/// curve using stablecoins of the protocol
contract BondingCurve is BondingCurveEvents, IBondingCurve, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Base used to compute ratios and floating numbers
    uint256 public constant BASE = 1e18;

    // ============================ References to contracts ========================

    /// @notice Interface for the token sold by this contract, most likely ANGLE tokens
    IERC20 public soldToken;

    /// @notice Address of the reference coin, the one other stablecoins are converted to
    /// @dev If the reference is not a stablecoin that can be used to buy tokens with this contract,
    /// this is set to 0
    /// @dev The reference stablecoin may change, but it would imply a change in all oracles,
    /// so it's important to be wary when updating it
    address public referenceCoin = address(0);

    // ============================ Parameters =====================================

    /// @notice Start price at which the bonding curve will sell
    /// This price will be expressed in a reference (most likely USD)
    uint256 public startPrice;

    /// @notice Power parameter for the bonding curve: the price is:
    /// `startPrice/(1-tokensSoldInTx/tokensToSellInTotal)^power`
    /// `power` should be strictly superior to 1
    uint256 public power;

    /// @notice Number of tokens to sell with this contract. It can be either increased or decreased
    uint256 public totalTokensToSell = 0;

    /// @notice Number of tokens sold so far. It should be inferior to `totalTokensToSell`
    uint256 public tokensSold = 0;

    /// @notice Maps a stablecoin that can be used to buy the token to the oracle contract that gives the price
    /// of the coin with respect to the reference stablecoin
    mapping(IAgToken => IOracle) public allowedStablecoins;

    // ============================ Modifier =======================================

    /// @notice Checks if the stablecoin is valid
    /// @dev The idea is to verify if there is an oracle associated to this contract or if this coin
    /// is the reference coin
    /// @dev It checks at the same time if `token` is non null. If `token` is not the reference then
    /// `allowedStablecoins[address(0)] == address(0)`.
    modifier isValid(IAgToken token) {
        require(
            (address(allowedStablecoins[token]) != address(0)) ||
                (referenceCoin == address(token) && referenceCoin != address(0)),
            "stablecoin not accepted"
        );
        _;
    }

    // ============================ Constructor ====================================

    /// @notice Initializes the `BondingCurve` contract
    /// @param governorList List of the governor addresses of the protocol
    /// @param guardian Address of the guardian
    /// @param _startPrice Start price of the token, it converts an amount of reference stablecoins to an amount
    /// of sold tokens (most of the time ANGLE tokens)
    /// @param _soldToken Token that it will be possible to buy using this contract
    /// @param _power Parameter for the bonding curve
    constructor(
        address[] memory governorList,
        address guardian,
        uint256 _startPrice,
        IERC20 _soldToken,
        uint256 _power
    ) {
        require(_power > 1, "invalid power parameter");
        require(guardian != address(0) && address(_soldToken) != address(0), "zero address");
        // Access control
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "zero address");
            _setupRole(GOVERNOR_ROLE, governorList[i]);
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }
        _setupRole(GUARDIAN_ROLE, guardian);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);

        startPrice = _startPrice;
        soldToken = _soldToken;
        power = _power;

        emit BondingCurveInit(startPrice, address(soldToken));
    }

    // ============================ Main Function ==================================

    /// @notice Lets `msg.sender` buy tokens (ANGLE tokens normally) against an allowed token (a stablecoin normally)
    /// @param _agToken Reference to the agToken used, that is the stablecoin used to buy the token associated to this
    /// bonding curve
    /// @param targetSoldTokenQuantity Target quantity of tokens to buy
    function buySoldToken(IAgToken _agToken, uint256 targetSoldTokenQuantity)
        external
        override
        whenNotPaused
        isValid(_agToken)
    {
        // Computing the number of reference stablecoins to burn to get the desired quantity
        // of tokens sold by this contract
        uint256 amountToPayInReference = _computePriceFromQuantity(targetSoldTokenQuantity);

        uint256 amountToPayInAgToken = 0;
        // The validity of the stablecoin has already been checked
        if (address(_agToken) == referenceCoin) {
            amountToPayInAgToken = amountToPayInReference;
        } else {
            // Converting a number of reference stablecoin to a number of desired stablecoin
            // using the oracle associated to each accepted stablecoin
            IOracle oracle = allowedStablecoins[_agToken];
            uint256 oracleValue = oracle.readLower(1);
            // There is no base problem here as it is a conversion between two Angle's agTokens
            // which are in base `BASE`
            amountToPayInAgToken = (amountToPayInReference * BASE) / oracleValue;
        }
        require(amountToPayInAgToken > 0, "oracle attack or incorrect value");

        emit TokenSale(targetSoldTokenQuantity, address(_agToken), amountToPayInAgToken);

        // Updating the internal variables
        tokensSold += targetSoldTokenQuantity;

        // Burning the correct amount of agToken
        _agToken.burnFromNoRedeem(msg.sender, amountToPayInAgToken);
        // Transfering the sold tokens to the caller
        soldToken.safeTransfer(msg.sender, targetSoldTokenQuantity);
    }

    // ============================ View Functions =================================

    /// @notice Returns the current price of the token (expressed in reference)
    /// @dev This is an external utility function
    function getCurrentPrice() external view returns (uint256) {
        if (_getQuantityLeftToSell() == 0) {
            return 0;
        }
        uint256 value = (startPrice * (totalTokensToSell**power)) / ((totalTokensToSell - tokensSold)**power) / BASE;
        return value;
    }

    /// @notice Returns the quantity of governance tokens that are still to be sold
    function getQuantityLeftToSell() external view returns (uint256) {
        return _getQuantityLeftToSell();
    }

    /// @notice Returns the amount to pay for the desired amount of ANGLE to buy
    /// @param targetQuantity Quantity of ANGLE tokens to buy
    /// @dev This is an utility function that can be queried before buying tokens
    function computePriceFromQuantity(uint256 targetQuantity) external view returns (uint256) {
        return _computePriceFromQuantity(targetQuantity);
    }

    // ============================ GOVERNANCE =====================================

    // ========================== Governor Function ================================

    /// @notice Transfers tokens from the bonding curve to another address
    /// @param amountToRecover Amount of tokens to transfer
    /// @param to Destination address
    /// @dev This function automatically updates the amount of tokens to sell and hence the price of the tokens,
    /// it should hence be called
    function recoverTokens(uint256 amountToRecover, address to) external onlyRole(GOVERNOR_ROLE) {
        // Updating the number of tokens to sell
        _changeTokensToSell(totalTokensToSell - amountToRecover);
        // No need to check the balance here
        soldToken.safeTransfer(to, amountToRecover);
    }

    // ========================== Guardian Functions ===============================

    /// @notice Allows a new stablecoin
    /// @param _agToken Reference to the agToken
    /// @param _oracle Reference to the oracle that will be used to have the price of this stablecoin in reference
    /// @param _isReference Whether this stablecoin will be the reference for oracles
    /// @dev To set a new reference coin, the old reference must have been revoked before
    /// @dev Calling this function for a stablecoin that already exists will just change its oracle if the
    /// agToken was already reference, and also set a new reference if the coin was already existing
    function allowNewStablecoin(
        IAgToken _agToken,
        IOracle _oracle,
        uint256 _isReference
    ) external onlyRole(GUARDIAN_ROLE) {
        require((_isReference == 0) || (_isReference == 1), "incorrect reference");
        require(address(_agToken) != address(0), "incorrect address");
        // It is impossible to change reference if the reference has not been revoked before
        // There is an hidden if in the followings require. If `_isReference` is true then
        // only the first require is important, otherwise only the second matters
        require((_isReference == 0) || (referenceCoin == address(0)), "already a reference");
        require((_isReference == 1) || (address(_oracle) != address(0)), "oracle required");

        if (_isReference == 1) {
            referenceCoin = address(_agToken);
        }
        // Oracle contract should give the price of the stablecoin with respect to the reference stablecoin
        allowedStablecoins[_agToken] = _oracle;

        emit ModifiedStablecoin(address(_agToken), (_isReference == 1), address(_oracle));
    }

    /// @notice Changes the oracle associated to a stablecoin
    /// @param _agToken Reference to the agToken
    /// @param _oracle Reference to the oracle that will be used to have the price of this stablecoin in reference
    /// @dev Oracle contract should be done with respect to reference
    function changeOracle(IAgToken _agToken, IOracle _oracle)
        external
        override
        onlyRole(GUARDIAN_ROLE)
        isValid(_agToken)
    {
        require((address(_oracle) != address(0)), "oracle required");
        allowedStablecoins[_agToken] = _oracle;
        emit ModifiedStablecoin(address(_agToken), referenceCoin == address(_agToken), address(_oracle));
    }

    /// @notice Revokes a stablecoin as a medium of payment
    /// @param _agToken Reference to the agToken
    function revokeStablecoin(IAgToken _agToken) external onlyRole(GUARDIAN_ROLE) {
        if (referenceCoin == address(_agToken)) {
            referenceCoin = address(0);
        }
        delete allowedStablecoins[_agToken];

        emit RevokedStablecoin(address(_agToken));
    }

    /// @notice Changes the start price (in reference)
    /// @param _startPrice New start price for the formula
    /// @dev This function may be useful to help re-collateralize the protocol in case of distress
    /// as it could allow to buy governance tokens at a discount
    function changeStartPrice(uint256 _startPrice) external onlyRole(GUARDIAN_ROLE) {
        require(_startPrice > 0, "incorrect start price");
        startPrice = _startPrice;

        emit StartPriceUpdated(_startPrice);
    }

    /// @notice Changes the total amount of tokens that can be sold with this bonding curve
    /// @param _totalTokensToSell New total amount of tokens to sell
    function changeTokensToSell(uint256 _totalTokensToSell) external onlyRole(GUARDIAN_ROLE) {
        _changeTokensToSell(_totalTokensToSell);
    }

    /// @notice Pauses the possibility to buy `soldToken` from the contract
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses and reactivates the possibility to buy tokens from the contract
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ============================ Internal =======================================

    /// @notice Internal version of the functions that changes the total tokens to sell
    /// @dev This function checks if the new amount of tokens to sell is compatible with what has already been sold
    /// and the balance of tokens of the contract
    /// @dev It can be used to decrease or increase what has already been sold
    function _changeTokensToSell(uint256 _totalTokensToSell) internal {
        require(_totalTokensToSell > tokensSold, "incorrect amount");
        require(soldToken.balanceOf(address(this)) >= _totalTokensToSell - tokensSold, "incorrect soldToken balance");
        totalTokensToSell = _totalTokensToSell;

        emit TokensToSellUpdated(_totalTokensToSell);
    }

    /// @notice Internal version of `getQuantityLeftToSell`
    function _getQuantityLeftToSell() internal view returns (uint256) {
        return totalTokensToSell - tokensSold;
    }

    /// @notice Internal version of `computePriceFromQuantity`
    /// @dev In the computation of the price, not all the multiplications are done before the divisions to avoid
    /// for overflows
    function _computePriceFromQuantity(uint256 targetQuantity) internal view returns (uint256 value) {
        uint256 leftToSell = _getQuantityLeftToSell();
        require(targetQuantity < leftToSell, "not enough token left to sell");

        // The formula to compute the amount to pay is the integral of the price over the bounds:
        // `tokensSold, tokensSold+targetQuantity`.
        // The integral is that of the inverse of a square root, hence the formula below
        uint256 leftToSellPowered = leftToSell**(power - 1);
        uint256 newLeftToSellPowered = (leftToSell - targetQuantity)**(power - 1);
        // The value to compute is:
        // `startPrice * totalTokensToSell **(power) * (leftToSellPowered - newLeftToSellPowered) /((power - 1) * BASE * leftToSellPowered * newLeftToSellPowered)`
        // If `totalTokensToSell` is `10**18 * (10**9)` (the maximum we could sell), then `totalTokensToSell ** power` is `(10**27)**power`
        // And `leftToSellPowered` is inferior to `totalTokensToSell ** (power - 1)`
        // Computation can hence be done as follows progressively without doing all the multiplications first
        value = (totalTokensToSell**power) / (leftToSellPowered * (power - 1));
        value = (value * startPrice) / BASE;
        value = (value * (leftToSellPowered - newLeftToSellPowered)) / newLeftToSellPowered;
    }
}
