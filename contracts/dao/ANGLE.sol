// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20VotesComp.sol";

/// @title ANGLE
/// @author Forked but improved from https://github.com/compound-finance/compound-protocol/tree/master/contracts/Governance
/// by Angle Core Team
/// @notice Governance token of Angle's protocol
contract ANGLE is ERC20VotesComp {
    /// @notice An event that is emitted when the minter address is changed
    event MinterChanged(address minter, address newMinter);

    /// These parameters are to be modified once deployed
    /// @notice Minimum time between mints
    uint32 public constant MINIMUM_BETWEEN_MINTS = 1 days * 30;

    /// @notice Cap on the percentage of `totalSupply()` that can be minted at each mint
    uint8 public constant MAX_MINT = 2;

    /// @notice Address which may mint new tokens
    address public minter;

    /// @notice The timestamp after which minting may occur
    uint256 public mintingAllowedAfter;

    /// @notice Constructs a new ANGLE token
    /// @param account Initial account to grant all the tokens to
    /// @param minter_ Account with minting ability
    constructor(address account, address minter_) ERC20Permit("ANGLE") ERC20("ANGLE", "ANGLE") {
        require(account != address(0) && minter_ != address(0), "zero address");
        _mint(account, 1_000_000_000e18); // 1 billion ANGLE
        minter = minter_;
        emit MinterChanged(address(0), minter);
        mintingAllowedAfter = block.timestamp;
    }

    /// @notice Changes the minter address
    /// @param minter_ Address of the new minter
    function setMinter(address minter_) external {
        require(msg.sender == minter, "only the minter can change the minter address");
        require(minter_ != address(0), "zero address");
        emit MinterChanged(minter, minter_);
        minter = minter_;
    }

    /// @notice Mints new tokens
    /// @param dst Address of the destination account
    /// @param amount Number of tokens to be minted
    function mint(address dst, uint256 amount) external {
        require(msg.sender == minter, "only the minter can mint");
        require(block.timestamp >= mintingAllowedAfter, "minting not allowed yet");
        require(amount <= (totalSupply() * MAX_MINT) / 100, "exceeded mint cap");
        // Record the mint
        mintingAllowedAfter = block.timestamp + MINIMUM_BETWEEN_MINTS;

        // Mint the amount
        _mint(dst, amount);
    }
}
