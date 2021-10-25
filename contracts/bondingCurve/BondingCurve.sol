// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.7;

import "./BondingCurveEvents.sol";

/// @title BondingCurve
/// @author Angle Core Team
/// @notice Enables anyone to buy ANGLE governance token or any type of token following a bonding
/// curve using stablecoins of the protocol
contract BondingCurve is BondingCurveEvents, IBondingCurve, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only: governor can change an oracle contract, recover tokens
    /// or take actions that are going to modify the price of the tokens
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Base used to compute ratios and floating numbers
    uint256 public constant BASE_TOKENS = 1e18;

    // ============================ References to contracts ========================

    /// @notice Interface for the token sold by this contract, most likely ANGLE tokens
    IERC20 public immutable soldToken;

    /// @notice Address of the reference coin, the one other stablecoins are converted to
    /// @dev If the reference is not a stablecoin that can be used to buy tokens with this contract,
    /// this is set to 0
    /// @dev The reference stablecoin may change, but it would imply a change in all oracles,
    /// so it's important to be wary when updating it
    /// @dev The reference does not necessarily have to be an accepted stablecoin by the system
    address public referenceCoin = address(0);

    // ============================ Parameters =====================================

    /// @notice Start price at which the bonding curve will sell
    /// This price will be expressed in a reference (most likely USD or EUR)
    uint256 public startPrice;

    /// @notice Number of tokens to sell with this contract. It can be either increased or decreased
    uint256 public totalTokensToSell;

    /// @notice Number of tokens sold so far. It should be inferior to `totalTokensToSell`
    uint256 public tokensSold;

    /// @notice Maps a stablecoin that can be used to buy the token to the oracle contract that gives the price
    /// of the coin with respect to the reference stablecoin
    mapping(IAgToken => IOracle) public allowedStablecoins;

    // ============================ Modifier =======================================

    /// @notice Checks if the stablecoin is valid
    /// @dev This modifier verifies if there is an oracle associated to this contract or if this coin
    /// is the reference coin
    /// @dev It checks at the same time if `token` is non null. If `token` is not the reference then
    /// `allowedStablecoins[address(0)] == address(0)`
    modifier isValid(IAgToken token) {
        require(
            (address(allowedStablecoins[token]) != address(0)) ||
                (referenceCoin == address(token) && referenceCoin != address(0)),
            "45"
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
    constructor(
        address[] memory governorList,
        address guardian,
        uint256 _startPrice,
        IERC20 _soldToken
    ) {
        require(guardian != address(0) && address(_soldToken) != address(0), "0");
        // Access control
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != address(0), "0");
            _setupRole(GOVERNOR_ROLE, governorList[i]);
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }
        _setupRole(GUARDIAN_ROLE, guardian);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);

        startPrice = _startPrice;
        soldToken = _soldToken;

        emit BondingCurveInit(startPrice, address(_soldToken));
    }

    // ============================ Main Function ==================================

    /// @notice Lets `msg.sender` buy tokens (ANGLE tokens normally) against an allowed token (a stablecoin normally)
    /// @param _agToken Reference to the agToken used, that is the stablecoin used to buy the token associated to this
    /// bonding curve
    /// @param targetSoldTokenQuantity Target quantity of tokens to buy
    /// @param maxAmountToPayInAgToken Maximum amount to pay in agTokens that the user is willing to pay to buy the
    /// `targetSoldTokenQuantity`
    function buySoldToken(
        IAgToken _agToken,
        uint256 targetSoldTokenQuantity,
        uint256 maxAmountToPayInAgToken
    ) external override whenNotPaused isValid(_agToken) {
        require(targetSoldTokenQuantity > 0, "4");
        // Computing the number of reference stablecoins to burn to get the desired quantity
        // of tokens sold by this contract
        uint256 amountToPayInReference = _computePriceFromQuantity(targetSoldTokenQuantity);

        uint256 amountToPayInAgToken;
        // The validity of the stablecoin has already been checked
        if (address(_agToken) == referenceCoin) {
            amountToPayInAgToken = amountToPayInReference;
        } else {
            // Converting a number of reference stablecoin to a number of desired stablecoin
            // using the oracle associated to each accepted stablecoin
            IOracle oracle = allowedStablecoins[_agToken];
            uint256 oracleValue = oracle.readLower();
            // There is no base problem here as it is a conversion between two Angle's agTokens
            // which are in base `BASE_TOKENS`
            amountToPayInAgToken = (amountToPayInReference * BASE_TOKENS) / oracleValue;
        }
        require(amountToPayInAgToken > 0 && amountToPayInAgToken <= maxAmountToPayInAgToken, "50");

        // Transferring the correct amount of agToken
        _agToken.transferFrom(msg.sender, address(this), amountToPayInAgToken);

        emit TokenSale(targetSoldTokenQuantity, address(_agToken), amountToPayInAgToken);
        // Updating the internal variables
        tokensSold += targetSoldTokenQuantity;

        // Transfering the sold tokens to the caller
        soldToken.safeTransfer(msg.sender, targetSoldTokenQuantity);
    }

    // ============================ View Functions =================================

    /// @notice Returns the current price of the token (expressed in reference)
    /// @dev This is an external utility function
    /// @dev More generally than the expression used, the value of the price is:
    /// `startPrice / (1 - tokensSoldInTx / tokensToSellInTotal) ^ 2`
    /// @dev The precision of this function is not that important as it is a view function anyone can query
    function getCurrentPrice() external view returns (uint256) {
        if (_getQuantityLeftToSell() == 0) {
            return 0;
        }
        return (totalTokensToSell**2 * startPrice) / ((totalTokensToSell - tokensSold)**2);
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

    // ========================== Governor Functions ===============================

    /// @notice Transfers tokens from the bonding curve to another address
    /// @param tokenAddress Address of the token to recover
    /// @param amountToRecover Amount of tokens to transfer
    /// @param to Destination address
    /// @dev This function automatically updates the amount of tokens to sell and hence the price of the tokens
    /// in case the token recovered is the token handled by this contract
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amountToRecover
    ) external onlyRole(GOVERNOR_ROLE) {
        if (tokenAddress == address(soldToken)) {
            // Updating the number of tokens to sell
            _changeTokensToSell(totalTokensToSell - amountToRecover);
            // No need to check the balance here
            soldToken.safeTransfer(to, amountToRecover);
        } else {
            IERC20(tokenAddress).safeTransfer(to, amountToRecover);
        }
        emit Recovered(tokenAddress, to, amountToRecover);
    }

    /// @notice Changes the oracle associated to a stablecoin
    /// @param _agToken Reference to the agToken
    /// @param _oracle Reference to the oracle that will be used to have the price of this stablecoin in reference
    /// @dev Oracle contract should give a price with respect to reference
    /// @dev This function should only be called by governance as it can be used to manipulate prices
    function changeOracle(IAgToken _agToken, IOracle _oracle)
        external
        override
        onlyRole(GOVERNOR_ROLE)
        isValid(_agToken)
    {
        require((address(_oracle) != address(0)), "51");
        allowedStablecoins[_agToken] = _oracle;
        emit ModifiedStablecoin(address(_agToken), referenceCoin == address(_agToken), address(_oracle));
    }

    /// @notice Allows a new stablecoin
    /// @param _agToken Reference to the agToken
    /// @param _oracle Reference to the oracle that will be used to have the price of this stablecoin in reference
    /// @param _isReference Whether this stablecoin will be the reference for oracles
    /// @dev To set a new reference coin, the old reference must have been revoked before
    /// @dev Calling this function for a stablecoin that already exists will just change its oracle if the
    /// agToken was already reference, and also set a new reference if the coin was already existing
    /// @dev Since this function could be used to deploy a new stablecoin with a really low oracle value, it has
    /// been made governor only
    function allowNewStablecoin(
        IAgToken _agToken,
        IOracle _oracle,
        uint256 _isReference
    ) external onlyRole(GOVERNOR_ROLE) {
        require((_isReference == 0) || (_isReference == 1), "9");
        require(address(_agToken) != address(0), "40");
        // It is impossible to change reference if the reference has not been revoked before
        // There is an hidden if in the followings require. If `_isReference` is true then
        // only the first require is important, otherwise only the second matters
        require((_isReference == 0) || (referenceCoin == address(0)), "52");
        require((_isReference == 1) || (address(_oracle) != address(0)), "51");

        if (_isReference == 1) {
            referenceCoin = address(_agToken);
        }
        // Oracle contract should give the price of the stablecoin with respect to the reference stablecoin
        allowedStablecoins[_agToken] = _oracle;

        emit ModifiedStablecoin(address(_agToken), (_isReference == 1), address(_oracle));
    }

    /// @notice Changes the start price (in reference)
    /// @param _startPrice New start price for the formula
    /// @dev This function may be useful to help re-collateralize the protocol in case of distress
    /// as it could allow to buy governance tokens at a discount
    /// @dev As this function can manipulate the price, it has to be governor only
    function changeStartPrice(uint256 _startPrice) external onlyRole(GOVERNOR_ROLE) {
        require(_startPrice > 0, "53");
        startPrice = _startPrice;

        emit StartPriceUpdated(_startPrice);
    }

    /// @notice Changes the total amount of tokens that can be sold with this bonding curve
    /// @param _totalTokensToSell New total amount of tokens to sell
    /// @dev As this function can manipulate the price, it has to be governor only
    function changeTokensToSell(uint256 _totalTokensToSell) external onlyRole(GOVERNOR_ROLE) {
        _changeTokensToSell(_totalTokensToSell);
    }

    // ========================== Guardian Functions ===============================

    /// @notice Revokes a stablecoin as a medium of payment
    /// @param _agToken Reference to the agToken
    /// @dev If the `referenceCoin` is revoked, contract should be paused to let governance update parameters
    /// like the `oracle` contracts associated to each allowed stablecoin or the start price
    /// @dev It is also possible that the contract works without a reference stablecoin: if the reference coin
    /// was USD but agUSD are no longer accepted, we may still want all the oracles and prices to be expressed
    /// in USD
    function revokeStablecoin(IAgToken _agToken) external onlyRole(GUARDIAN_ROLE) {
        if (referenceCoin == address(_agToken)) {
            referenceCoin = address(0);
            _pause();
        }
        delete allowedStablecoins[_agToken];

        emit RevokedStablecoin(address(_agToken));
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
        require(_totalTokensToSell > tokensSold, "54");
        require(soldToken.balanceOf(address(this)) >= _totalTokensToSell - tokensSold, "56");
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
    /// @dev The formula to compute the amount to pay is the integral of a the price over the bounds:
    /// `tokensSold, tokensSold+targetQuantity`
    /// @dev The integral computed by this function is the integral of the inverse of a square root
    function _computePriceFromQuantity(uint256 targetQuantity) internal view returns (uint256 value) {
        uint256 leftToSell = _getQuantityLeftToSell();
        require(targetQuantity < leftToSell, "55");

        // The global value to compute is (with `power = 2` here):
        // `startPrice * totalTokensToSell **(power) * (leftToSell ** (power - 1) - (leftToSell - targetQuantity) ** (power - 1)) /((power - 1) * BASE_TOKENS * leftToSell ** (power - 1) * (leftToSell - targetQuantity) ** (power - 1))`
        // If `totalTokensToSell` is `10**18 * (10**9)` (the maximum we could sell), then `totalTokensToSell ** power` is `(10**27)**power`
        // And `leftToSell ** (power - 1) ` is inferior to `totalTokensToSell ** power`
        // In this case the fact that power = 2 simplifies the computation
        // Computation can hence be done as follows progressively without doing all the multiplications first to avoid overflows
        value = (totalTokensToSell**2) / leftToSell;
        value = (value * startPrice) / BASE_TOKENS;
        value = (value * targetQuantity) / (leftToSell - targetQuantity);
    }
}
