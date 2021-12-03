// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "./CoreEvents.sol";

/// @title Core
/// @author Angle Core Team
/// @notice Keeps track of all the `StableMaster` contracts and facilitates governance by allowing the propagation
/// of changes across most contracts of the protocol (does not include oracle contract, `RewardsDistributor`, and some
/// other side contracts like `BondingCurve` or `CollateralSettler`)
contract Core is CoreEvents, ICore {
    /// @notice Map to track the addresses with a `GOVERNOR_ROLE` within Angle protocol
    mapping(address => bool) public governorMap;

    /// @notice Map to track the addresses of the `stableMaster` contracts that have already been deployed
    /// This is used to avoid deploying a revoked `stableMaster` contract again and hence potentially creating
    /// inconsistencies in the `GOVERNOR_ROLE` and `GUARDIAN_ROLE` of this `stableMaster`
    mapping(address => bool) public deployedStableMasterMap;

    /// @notice Address of the guardian, it can be revoked by Angle's governance
    /// The protocol has only one guardian address
    address public override guardian;

    /// @notice List of the addresses of the `StableMaster` contracts accepted by the system
    address[] internal _stablecoinList;

    // List of all the governor addresses of Angle's protocol
    // Initially only the timelock will be appointed governor but new addresses can be added along the way
    address[] internal _governorList;

    /// @notice Checks to see if the caller is a `governor`
    /// The reason for having such modifiers rather than OpenZeppelin's Access Control logic is to make
    /// sure that governors cannot bypass the `addGovernor` or `revokeGovernor` functions
    modifier onlyGovernor() {
        require(governorMap[msg.sender], "1");
        _;
    }

    /// @notice Checks to see if the caller is a `guardian` or a `governor`
    /// Same here, we do not use OpenZeppelin's Access Control logic to make sure that the `guardian`
    /// cannot bypass the functions defined on purpose in this contract
    modifier onlyGuardian() {
        require(governorMap[msg.sender] || msg.sender == guardian, "1");
        _;
    }

    /// @notice Checks if the new address given is not null
    /// @param newAddress Address to check
    modifier zeroCheck(address newAddress) {
        require(newAddress != address(0), "0");
        _;
    }

    // =============================== CONSTRUCTOR =================================

    /// @notice Initializes the `Core` contract
    /// @param _governor Address of the governor
    /// @param _guardian Address of the guardian
    constructor(address _governor, address _guardian) {
        // Creating references
        require(_guardian != address(0) && _governor != address(0), "0");
        require(_guardian != _governor, "39");
        _governorList.push(_governor);
        guardian = _guardian;
        governorMap[_governor] = true;

        emit GovernorRoleGranted(_governor);
        emit GuardianRoleChanged(address(0), _guardian);
    }

    // ========================= GOVERNOR FUNCTIONS ================================

    // ======================== Interactions with `StableMasters` ==================

    /// @notice Changes the `Core` contract of the protocol
    /// @param newCore Address of the new `Core` contract
    /// @dev To maintain consistency, checks are performed. The governance of the new `Core`
    /// contract should be exactly the same as this one, and the `_stablecoinList` should be
    /// identical
    function setCore(ICore newCore) external onlyGovernor zeroCheck(address(newCore)) {
        require(address(this) != address(newCore), "40");
        require(guardian == newCore.guardian(), "41");
        // The length of the lists are stored as cache variables to avoid duplicate reads in storage
        // Checking the consistency of the `_governorList` and of the `_stablecoinList`
        uint256 governorListLength = _governorList.length;
        address[] memory _newCoreGovernorList = newCore.governorList();
        uint256 stablecoinListLength = _stablecoinList.length;
        address[] memory _newStablecoinList = newCore.stablecoinList();
        require(
            governorListLength == _newCoreGovernorList.length && stablecoinListLength == _newStablecoinList.length,
            "42"
        );
        uint256 indexMet;
        for (uint256 i = 0; i < governorListLength; i++) {
            if (!governorMap[_newCoreGovernorList[i]]) {
                indexMet = 1;
                break;
            }
        }
        for (uint256 i = 0; i < stablecoinListLength; i++) {
            // The stablecoin lists should preserve exactly the same order of elements
            if (_stablecoinList[i] != _newStablecoinList[i]) {
                indexMet = 1;
                break;
            }
        }
        // Only performing one require, hence making it cheaper for a governance with a correct initialization
        require(indexMet == 0, "43");
        // Propagates the change
        for (uint256 i = 0; i < stablecoinListLength; i++) {
            IStableMaster(_stablecoinList[i]).setCore(address(newCore));
        }
        emit CoreChanged(address(newCore));
    }

    /// @notice Adds a new stablecoin to the system
    /// @param agToken Address of the new `AgToken` contract
    /// @dev To maintain consistency, the address of the `StableMaster` contract corresponding to the
    /// `AgToken` is automatically retrieved
    /// @dev The `StableMaster` receives the reference to the governor and guardian addresses of the protocol
    /// @dev The `AgToken` and `StableMaster` contracts should have previously been initialized with correct references
    /// in it, with for the `StableMaster` a reference to the `Core` contract and for the `AgToken` a reference to the
    /// `StableMaster`
    function deployStableMaster(address agToken) external onlyGovernor zeroCheck(agToken) {
        address stableMaster = IAgToken(agToken).stableMaster();
        // Checking if `stableMaster` has not already been deployed
        require(!deployedStableMasterMap[stableMaster], "44");

        // Storing and initializing information about the stablecoin
        _stablecoinList.push(stableMaster);
        // Adding this `stableMaster` in the `deployedStableMasterMap`: it is not going to be possible
        // to revoke and then redeploy this contract
        deployedStableMasterMap[stableMaster] = true;

        IStableMaster(stableMaster).deploy(_governorList, guardian, agToken);

        emit StableMasterDeployed(address(stableMaster), agToken);
    }

    /// @notice Revokes a `StableMaster` contract
    /// @param stableMaster Address of  the `StableMaster` to revoke
    /// @dev This function just removes a `StableMaster` contract from the `_stablecoinList`
    /// @dev The consequence is that the `StableMaster` contract will no longer be affected by changes in
    /// governor or guardian occuring from the protocol
    /// @dev This function is mostly here to clean the mappings and save some storage space
    function revokeStableMaster(address stableMaster) external override onlyGovernor {
        uint256 stablecoinListLength = _stablecoinList.length;
        // Checking if `stableMaster` is correct and removing the stablecoin from the `_stablecoinList`
        require(stablecoinListLength >= 1, "45");
        uint256 indexMet;
        for (uint256 i = 0; i < stablecoinListLength - 1; i++) {
            if (_stablecoinList[i] == stableMaster) {
                indexMet = 1;
                _stablecoinList[i] = _stablecoinList[stablecoinListLength - 1];
                break;
            }
        }
        require(indexMet == 1 || _stablecoinList[stablecoinListLength - 1] == stableMaster, "45");
        _stablecoinList.pop();
        // Deleting the stablecoin from the list
        emit StableMasterRevoked(stableMaster);
    }

    // =============================== Access Control ==============================
    // The following functions do not propagate the changes they induce to some bricks of the protocol
    // like the `CollateralSettler`, the `BondingCurve`, the staking and rewards distribution contracts
    // and the oracle contracts using Uniswap. Governance should be wary when calling these functions and
    // make equivalent changes in these contracts to maintain consistency at the scale of the protocol

    /// @notice Adds a new governor address
    /// @param _governor New governor address
    /// @dev This function propagates the new governor role across most contracts of the protocol
    /// @dev Governor is also guardian everywhere in all contracts
    function addGovernor(address _governor) external override onlyGovernor zeroCheck(_governor) {
        require(!governorMap[_governor], "46");
        governorMap[_governor] = true;
        _governorList.push(_governor);
        // Propagates the changes to maintain consistency across all the contracts that are attached to this
        // `Core` contract
        for (uint256 i = 0; i < _stablecoinList.length; i++) {
            // Since a zero address check has already been performed in this contract, there is no need
            // to repeat this check in underlying contracts
            IStableMaster(_stablecoinList[i]).addGovernor(_governor);
        }

        emit GovernorRoleGranted(_governor);
    }

    /// @notice Removes a governor address
    /// @param _governor Governor address to remove
    /// @dev There must always be one governor in the protocol
    function removeGovernor(address _governor) external override onlyGovernor {
        // Checking if removing the governor will leave with at least more than one governor
        uint256 governorListLength = _governorList.length;
        require(governorListLength > 1, "47");
        // Removing the governor from the list of governors
        // We still need to check if the address provided was well in the list
        uint256 indexMet;
        for (uint256 i = 0; i < governorListLength - 1; i++) {
            if (_governorList[i] == _governor) {
                indexMet = 1;
                _governorList[i] = _governorList[governorListLength - 1];
                break;
            }
        }
        require(indexMet == 1 || _governorList[governorListLength - 1] == _governor, "48");
        _governorList.pop();
        // Once it has been checked that the given address was a correct address, we can proceed to other changes
        delete governorMap[_governor];
        // Maintaining consistency across all contracts
        for (uint256 i = 0; i < _stablecoinList.length; i++) {
            // We have checked in this contract that the mentionned `_governor` here was well a governor
            // There is no need to check this in the underlying contracts where this is going to be updated
            IStableMaster(_stablecoinList[i]).removeGovernor(_governor);
        }

        emit GovernorRoleRevoked(_governor);
    }

    // ============================== GUARDIAN FUNCTIONS ===========================

    /// @notice Changes the guardian address
    /// @param _newGuardian New guardian address
    /// @dev Guardian is able to change by itself the address corresponding to its role
    /// @dev There can only be one guardian address in the protocol
    /// @dev The guardian address cannot be a governor address
    function setGuardian(address _newGuardian) external override onlyGuardian zeroCheck(_newGuardian) {
        require(!governorMap[_newGuardian], "39");
        require(guardian != _newGuardian, "49");
        address oldGuardian = guardian;
        guardian = _newGuardian;
        for (uint256 i = 0; i < _stablecoinList.length; i++) {
            IStableMaster(_stablecoinList[i]).setGuardian(_newGuardian, oldGuardian);
        }
        emit GuardianRoleChanged(oldGuardian, _newGuardian);
    }

    /// @notice Revokes the guardian address
    /// @dev Guardian is able to auto-revoke itself
    /// @dev There can only be one `guardian` address in the protocol
    function revokeGuardian() external override onlyGuardian {
        address oldGuardian = guardian;
        guardian = address(0);
        for (uint256 i = 0; i < _stablecoinList.length; i++) {
            IStableMaster(_stablecoinList[i]).revokeGuardian(oldGuardian);
        }
        emit GuardianRoleChanged(oldGuardian, address(0));
    }

    // ========================= VIEW FUNCTIONS ====================================

    /// @notice Returns the list of all the governor addresses of the protocol
    /// @return `_governorList`
    /// @dev This getter is used by `StableMaster` contracts deploying new collateral types
    /// and initializing them with correct references
    function governorList() external view override returns (address[] memory) {
        return _governorList;
    }

    /// @notice Returns the list of all the `StableMaster` addresses of the protocol
    /// @return `_stablecoinList`
    /// @dev This getter is used by the `Core` contract when setting a new `Core`
    function stablecoinList() external view override returns (address[] memory) {
        return _stablecoinList;
    }
}
