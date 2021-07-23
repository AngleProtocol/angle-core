// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.2;

import "./CoreEvents.sol";

/// @title Core
/// @author Angle Core Team
/// @notice Keeps track of all the `StableMaster` contracts and facilitates governance by allowing the propagation
/// of changes across all contracts of the protocol
contract Core is CoreEvents, ICoreFunctions, AccessControl, FunctionUtils, Initializable {
    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for guardians and governors
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice List of all the governor addresses of Angle's protocol
    /// Initially only the timelock will be appointed governor but new addresses can be added along the way
    address[] public governorList;

    /// @notice Address of the guardian, it can be revoked by Angle's governance
    /// The protocol has only one guardian address
    address public guardian;

    /// @notice List of all the stablecoins accepted by the system
    address[] public stablecoinList;

    // =============================== CONSTRUCTOR =================================

    /// @notice Initializes the `Core` contract
    /// @param _governor Address of the governor
    /// @param _guardian Address of the guardian
    constructor(address _governor, address _guardian) {
        // Creating references
        require(_guardian != address(0) && _governor != address(0), "zero address");
        require(_guardian != _governor, "guardian cannot be governor");
        governorList.push(_governor);
        guardian = _guardian;
        // Access Control
        // Governor is admin of all the roles in the `Core` contract
        _setupRole(GOVERNOR_ROLE, _governor);
        _setupRole(GUARDIAN_ROLE, _governor);
        _setupRole(GUARDIAN_ROLE, _guardian);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
    }

    // ========================= GOVERNOR FUNCTIONS ================================

    // ======================== Interactions with `StableMasters` ==================

    /// @notice Adds a new stablecoin to the system
    /// @param agToken Address of the new `AgToken` contract
    /// @dev To maintain consistency, the address of the `StableMaster` contract corresponding to the
    /// `AgToken` is automatically retrieved
    /// @dev The `StableMaster` is initialized with the correct references
    /// @dev The `AgToken` and `StableMaster` contracts should have previously been initialized with correct references
    /// in it, with for the `StableMaster` a reference to the `Core` contract and for the `AgToken` a reference to the
    /// `StableMaster`
    function deployStableMaster(address agToken) external onlyRole(GOVERNOR_ROLE) zeroCheck(agToken) {
        address stableMaster = IAgToken(agToken).stableMaster();

        // Checking if `stableMaster` is not already deployed
        uint256 indexMet = 0;
        for (uint256 i = 0; i < stablecoinList.length; i++) {
            if (stablecoinList[i] == stableMaster) {
                indexMet = 1;
            }
        }
        require(indexMet == 0, "stableMaster already deployed");

        // Storing and initializing information about the stablecoin
        stablecoinList.push(stableMaster);

        IStableMaster(stableMaster).deploy(governorList, guardian, agToken);

        emit StableMasterDeployed(address(stableMaster), agToken);
    }

    /// @notice Revokes a `StableMaster` contract
    /// @param stableMaster Address of  the `StableMaster` to revoke
    /// @dev This function just removes a `StableMaster` contract from the `stablecoinList`
    /// @dev The consequence is that the `StableMaster` contract will no longer be affected by changes in
    /// governor or guardian occuring from the protocol
    /// @dev This function is mostly here to clean the mappings and save some storage space
    function revokeStableMaster(address stableMaster) external override onlyRole(GOVERNOR_ROLE) {
        // Checking if `stableMaster` is correct and removing the stablecoin from the `stablecoinList`
        uint256 indexMet = 0;
        for (uint256 i = 0; i < stablecoinList.length - 1; i++) {
            if (stablecoinList[i] == stableMaster) {
                indexMet = 1;
            }
            if (indexMet == 1) {
                stablecoinList[i] = stablecoinList[i + 1];
            }
        }
        require(indexMet == 1 || stablecoinList[stablecoinList.length - 1] == stableMaster, "incorrect stablecoin");
        stablecoinList.pop();
        // Deleting the stablecoin from the mapping
        emit StableMasterRevoked(stableMaster);
    }

    // =============================== Access Control ==============================
    // The following functions do not propagate the changes they induce to some bricks of the protocol
    // like the `CollateralSettler`, the `BondingCurve`, the staking and rewards distribution contracts
    // and the oracle contracts using Uniswap. Governance should be wary when calling these functions and
    // make equivalent changes in these contracts to maintain consistency at the scale of the protocol

    /// @notice Adds a new governor address
    /// @param _governor New governor address
    /// @dev This function propagates the new governor role across all contracts of the protocol
    /// @dev Governor is also guardian everywhere in all contracts
    function addGovernor(address _governor) external override onlyRole(GOVERNOR_ROLE) zeroCheck(_governor) {
        // Each governor address can only be present once in the list
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != _governor, "governor already added");
        }
        grantRole(GOVERNOR_ROLE, _governor);
        grantRole(GUARDIAN_ROLE, _governor);
        governorList.push(_governor);
        // Propagates the changes to maintain consistency across all contracts
        for (uint256 i = 0; i < stablecoinList.length; i++) {
            // Since a zero address check has already been performed in this contract, there is no need
            // to repeat this check in underlying contracts
            IStableMaster(stablecoinList[i]).addGovernor(_governor);
        }
    }

    /// @notice Removes a governor address
    /// @param _governor Governor address to remove
    /// @dev There must always be one governor in the protocol
    function removeGovernor(address _governor) external override onlyRole(GOVERNOR_ROLE) {
        // Checking if removing the governor will leave with at least more than one governor
        require(governorList.length > 1, "only one governor");
        // Removing the governor from the list of governors
        // We still need to check if the address provided was well in the list
        uint256 indexMet = 0;
        for (uint256 i = 0; i < governorList.length - 1; i++) {
            if (governorList[i] == _governor) {
                indexMet = 1;
            }
            if (indexMet == 1) {
                governorList[i] = governorList[i + 1];
            }
        }
        require(indexMet == 1 || governorList[governorList.length - 1] == _governor, "governor not in the list");
        governorList.pop();
        // Once it has been checked that the given address was a correct address, we can proceed to other changes
        revokeRole(GUARDIAN_ROLE, _governor);
        revokeRole(GOVERNOR_ROLE, _governor);
        // Maintaining consistency across all contracts
        for (uint256 i = 0; i < stablecoinList.length; i++) {
            // We have checked in this contract that the mentionned `_governor` here was well a governor
            // There is no need to check this in the underlying contracts where this is going to be updated
            IStableMaster(stablecoinList[i]).removeGovernor(_governor);
        }
    }

    // ============================== GUARDIAN FUNCTIONS ===========================

    /// @notice Changes the guardian address
    /// @param _guardian New guardian address
    /// @dev Guardian is able to change by itself the address corresponding to its role
    /// @dev There can only be one guardian address in the protocol
    /// @dev The guardian address cannot be a governor address
    function setGuardian(address _guardian) external override onlyRole(GUARDIAN_ROLE) zeroCheck(_guardian) {
        for (uint256 i = 0; i < governorList.length; i++) {
            require(governorList[i] != _guardian, "guardian cannot be governor");
        }
        grantRole(GUARDIAN_ROLE, _guardian);
        revokeRole(GUARDIAN_ROLE, guardian);
        address oldGuardian = guardian;
        guardian = _guardian;
        for (uint256 i = 0; i < stablecoinList.length; i++) {
            IStableMaster(stablecoinList[i]).setGuardian(_guardian, oldGuardian);
        }
    }

    /// @notice Revokes the guardian address
    /// @dev Guardian is able to auto-revoke itself
    /// @dev There can only be one `guardian` address in the protocol
    function revokeGuardian() external override onlyRole(GUARDIAN_ROLE) {
        revokeRole(GUARDIAN_ROLE, guardian);
        address oldGuardian = guardian;
        guardian = address(0);
        for (uint256 i = 0; i < stablecoinList.length; i++) {
            IStableMaster(stablecoinList[i]).revokeGuardian(oldGuardian);
        }
    }

    // ========================= VIEW FUNCTIONS ====================================

    /// @notice Returns the list of all the governor addresses of the protocol
    /// @return `governorList`
    /// @dev This getter is used by `StableMaster` contracts deploying new collateral types
    /// and initializing them with correct references
    function getGovernorList() external view override returns (address[] memory) {
        return governorList;
    }
}
