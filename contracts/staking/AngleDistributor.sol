// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

import "./AngleDistributorEvents.sol";

/// @title AngleDistributor
/// @author Forked from contracts developed by Curve and Frax and adapted by Angle Core Team
/// - ERC20CRV.vy (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/ERC20CRV.vy)
/// - FraxGaugeFXSRewardsDistributor.sol (https://github.com/FraxFinance/frax-solidity/blob/master/src/hardhat/contracts/Curve/FraxGaugeFXSRewardsDistributor.sol)
/// @notice All the events used in `AngleDistributor` contract
contract AngleDistributor is AngleDistributorEvents, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Role for governors only
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Role for the guardian
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Length of a week in seconds
    uint256 public constant WEEK = 3600 * 24 * 7;

    /// @notice Time at which the emission rate is updated
    uint256 public constant RATE_REDUCTION_TIME = WEEK;

    /// @notice Reduction of the emission rate
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1007827884862117171; // 1.5 ^ (1/52) * 10**18

    /// @notice Base used for computation
    uint256 public constant BASE = 10**18;

    /// @notice Maps the address of a gauge to the last time this gauge received rewards
    mapping(address => uint256) public lastTimeGaugePaid;

    /// @notice Maps the address of a gauge to whether it was killed or not
    /// A gauge killed in this contract cannot receive any rewards
    mapping(address => bool) public killedGauges;

    /// @notice Maps the address of a type >= 2 gauge to a delegate address responsible
    /// for giving rewards to the actual gauge
    mapping(address => address) public delegateGauges;

    /// @notice Maps the address of a gauge delegate to whether this delegate supports the `notifyReward` interface
    /// and is therefore built for automation
    mapping(address => bool) public isInterfaceKnown;

    /// @notice Address of the ANGLE token given as a reward
    IERC20 public rewardToken;

    /// @notice Address of the `GaugeController` contract
    IGaugeController public controller;

    /// @notice Address responsible for pulling rewards of type >= 2 gauges and distributing it to the
    /// associated contracts if there is not already an address delegated for this specific contract
    address public delegateGauge;

    /// @notice ANGLE current emission rate, it is first defined in the initializer and then updated every week
    uint256 public rate;

    /// @notice Timestamp at which the current emission epoch started
    uint256 public startEpochTime;

    /// @notice Amount of ANGLE tokens distributed through staking at the start of the epoch
    /// This is an informational variable used to track how much has been distributed through liquidity mining
    uint256 public startEpochSupply;

    /// @notice Index of the current emission epoch
    /// Here also, this variable is not useful per se inside the smart contracts of the protocol, it is
    /// just an informational variable
    uint256 public miningEpoch;

    /// @notice Whether ANGLE distribution through this contract is on or no
    bool public distributionsOn;

    /// @notice Constructor of the contract
    /// @param _rewardToken Address of the ANGLE token
    /// @param _controller Address of the GaugeController
    /// @param _initialRate Initial ANGLE emission rate
    /// @param _startEpochSupply Amount of ANGLE tokens already distributed via liquidity mining
    /// @param governor Governor address of the contract
    /// @param guardian Address of the guardian of this contract
    /// @param _delegateGauge Address that will be used to pull rewards for type 2 gauges
    /// @dev After this contract is created, the correct amount of ANGLE tokens should be transferred to the contract
    /// @dev The `_delegateGauge` can be the zero address
    function initialize(
        address _rewardToken,
        address _controller,
        uint256 _initialRate,
        uint256 _startEpochSupply,
        address governor,
        address guardian,
        address _delegateGauge
    ) external initializer {
        require(
            _controller != address(0) && _rewardToken != address(0) && guardian != address(0) && governor != address(0),
            "0"
        );
        rewardToken = IERC20(_rewardToken);
        controller = IGaugeController(_controller);
        startEpochSupply = _startEpochSupply;
        miningEpoch = 0;
        // Some ANGLE tokens should be sent to the contract directly after initialization
        rate = _initialRate;
        delegateGauge = _delegateGauge;
        distributionsOn = false;
        startEpochTime = block.timestamp;
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNOR_ROLE);
        _setupRole(GUARDIAN_ROLE, guardian);
        _setupRole(GOVERNOR_ROLE, governor);
        _setupRole(GUARDIAN_ROLE, governor);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // ======================== Internal Functions =================================

    /// @notice Internal function to distribute rewards to a gauge
    /// @param gaugeAddr Address of the gauge to distribute rewards to
    /// @return weeksElapsed Weeks elapsed since the last call
    /// @return rewardTally Amount of rewards distributed to the gauge
    /// @dev The reason for having an internal function is that it's called by the `distributeReward` and the
    /// `distributeRewardToMultipleGauges`
    /// @dev Although they would need to be performed all the time this function is called, this function does not
    /// contain checks on whether distribution is on, and on whether rate should be reduced. These are done in each external
    /// function calling this function for gas efficiency
    function _distributeReward(address gaugeAddr) internal returns (uint256 weeksElapsed, uint256 rewardTally) {
        // Checking if the gauge has been added or if it still possible to distribute rewards to this gauge
        int128 gaugeType = IGaugeController(controller).gauge_types(gaugeAddr);
        require(gaugeType >= 0 && !killedGauges[gaugeAddr], "110");

        // Calculate the elapsed time in weeks.
        uint256 lastTimePaid = lastTimeGaugePaid[gaugeAddr];

        // Edge case for first reward for this gauge
        if (lastTimePaid == 0) {
            weeksElapsed = 1;
            if (gaugeType == 0) {
                // We give a full approval for the gauges with type zero which correspond to the staking
                // contracts of the protocol
                rewardToken.safeApprove(gaugeAddr, type(uint256).max);
            }
        } else {
            // Truncation desired
            weeksElapsed = (block.timestamp - lastTimePaid) / WEEK;
            // Return early here for 0 weeks instead of throwing, as it could have bad effects in other contracts
            if (weeksElapsed == 0) {
                return (0, 0);
            }
        }
        rewardTally = 0;
        // We use this variable to keep track of the emission rate across different weeks
        uint256 weeklyRate = rate;
        for (uint256 i = 0; i < weeksElapsed; i++) {
            uint256 relWeightAtWeek;
            if (i == 0) {
                // Mutative, for the current week: makes sure the weight is checkpointed. Also returns the weight.
                relWeightAtWeek = controller.gauge_relative_weight_write(gaugeAddr, block.timestamp);
            } else {
                // View
                relWeightAtWeek = controller.gauge_relative_weight(gaugeAddr, (block.timestamp - WEEK * i));
            }
            rewardTally += (weeklyRate * relWeightAtWeek * WEEK) / BASE;

            // To get the rate of the week prior from the current rate we just have to multiply by the weekly division
            // factor
            // There may be some precisions error: inferred previous values of the rate may be different to what we would
            // have had if the rate had been computed correctly in these weeks: we expect from empirical observations
            // this `weeklyRate` to be inferior to what the `rate` would have been
            weeklyRate = (weeklyRate * RATE_REDUCTION_COEFFICIENT) / BASE;
        }

        // Update the last time paid, rounded to the closest week
        // in order not to have an ever moving time on when to call this function
        lastTimeGaugePaid[gaugeAddr] = (block.timestamp / WEEK) * WEEK;

        // If the `gaugeType >= 2`, this means that the gauge is a gauge on another chain (and corresponds to tokens
        // that need to be bridged) or is associated to an external contract of the Angle Protocol
        if (gaugeType >= 2) {
            // If it is defined, we use the specific delegate attached to the gauge
            address delegate = delegateGauges[gaugeAddr];
            if (delegate == address(0)) {
                // If not, we check if a delegate common to all gauges with type >= 2 can be used
                delegate = delegateGauge;
            }
            if (delegate != address(0)) {
                // In the case where the gauge has a delegate (specific or not), then rewards are transferred to this gauge
                rewardToken.safeTransfer(delegate, rewardTally);
                // If this delegate supports a specific interface, then rewards sent are notified through this
                // interface
                if (isInterfaceKnown[delegate]) {
                    IAngleMiddlemanGauge(delegate).notifyReward(gaugeAddr, rewardTally);
                }
            } else {
                rewardToken.safeTransfer(gaugeAddr, rewardTally);
            }
        } else if (gaugeType == 1) {
            // This is for the case of Perpetual contracts which need to be able to receive their reward tokens
            rewardToken.safeTransfer(gaugeAddr, rewardTally);
            IStakingRewards(gaugeAddr).notifyRewardAmount(rewardTally);
        } else {
            // Mainnet: Pay out the rewards directly to the gauge
            ILiquidityGauge(gaugeAddr).deposit_reward_token(address(rewardToken), rewardTally);
        }
        emit RewardDistributed(gaugeAddr, rewardTally);
    }

    /// @notice Updates mining rate and supply at the start of the epoch
    /// @dev Any modifying mining call must also call this
    /// @dev It is possible that more than one week past between two calls of this function, and for this reason
    /// this function has been slightly modified from Curve implementation by Angle Team
    function _updateMiningParameters() internal {
        // When entering this function, we always have: `(block.timestamp - startEpochTime) / RATE_REDUCTION_TIME >= 1`
        uint256 epochDelta = (block.timestamp - startEpochTime) / RATE_REDUCTION_TIME;

        // Storing intermediate values for the rate and for the `startEpochSupply`
        uint256 _rate = rate;
        uint256 _startEpochSupply = startEpochSupply;

        startEpochTime += RATE_REDUCTION_TIME * epochDelta;
        miningEpoch += epochDelta;

        for (uint256 i = 0; i < epochDelta; i++) {
            // Updating the intermediate values of the `startEpochSupply`
            _startEpochSupply += _rate * RATE_REDUCTION_TIME;
            _rate = (_rate * BASE) / RATE_REDUCTION_COEFFICIENT;
        }
        rate = _rate;
        startEpochSupply = _startEpochSupply;
        emit UpdateMiningParameters(block.timestamp, _rate, _startEpochSupply);
    }

    /// @notice Toggles the fact that a gauge delegate can be used for automation or not and therefore supports
    /// the `notifyReward` interface
    /// @param _delegateGauge Address of the gauge to change
    function _toggleInterfaceKnown(address _delegateGauge) internal {
        bool isInterfaceKnownMem = isInterfaceKnown[_delegateGauge];
        isInterfaceKnown[_delegateGauge] = !isInterfaceKnownMem;
        emit InterfaceKnownToggled(_delegateGauge, !isInterfaceKnownMem);
    }

    // ================= Permissionless External Functions =========================

    /// @notice Distributes rewards to a staking contract (also called gauge)
    /// @param gaugeAddr Address of the gauge to send tokens too
    /// @return weeksElapsed Number of weeks elapsed since the last time rewards were distributed
    /// @return rewardTally Amount of tokens sent to the gauge
    /// @dev Anyone can call this function to distribute rewards to the different staking contracts
    function distributeReward(address gaugeAddr) external nonReentrant returns (uint256, uint256) {
        // Checking if distribution is on
        require(distributionsOn == true, "109");
        // Updating rate distribution parameters if need be
        if (block.timestamp >= startEpochTime + RATE_REDUCTION_TIME) {
            _updateMiningParameters();
        }
        return _distributeReward(gaugeAddr);
    }

    /// @notice Distributes rewards to multiple staking contracts
    /// @param gauges Addresses of the gauge to send tokens too
    /// @dev Anyone can call this function to distribute rewards to the different staking contracts
    /// @dev Compared with the `distributeReward` function, this function sends rewards to multiple
    /// contracts at the same time
    function distributeRewardToMultipleGauges(address[] memory gauges) external nonReentrant {
        // Checking if distribution is on
        require(distributionsOn == true, "109");
        // Updating rate distribution parameters if need be
        if (block.timestamp >= startEpochTime + RATE_REDUCTION_TIME) {
            _updateMiningParameters();
        }
        for (uint256 i = 0; i < gauges.length; i++) {
            _distributeReward(gauges[i]);
        }
    }

    /// @notice Updates mining rate and supply at the start of the epoch
    /// @dev Callable by any address, but only once per epoch
    function updateMiningParameters() external {
        require(block.timestamp >= startEpochTime + RATE_REDUCTION_TIME, "108");
        _updateMiningParameters();
    }

    // ========================= Governor Functions ================================

    /// @notice Withdraws ERC20 tokens that could accrue on this contract
    /// @param tokenAddress Address of the ERC20 token to withdraw
    /// @param to Address to transfer to
    /// @param amount Amount to transfer
    /// @dev Added to support recovering LP Rewards and other mistaken tokens
    /// from other systems to be distributed to holders
    /// @dev This function could also be used to recover ANGLE tokens in case the rate got smaller
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amount
    ) external onlyRole(GOVERNOR_ROLE) {
        // If the token is the ANGLE token, we need to make sure that governance is not going to withdraw
        // too many tokens and that it'll be able to sustain the weekly distribution forever
        // This check assumes that `distributeReward` has been called for gauges and that there are no gauges
        // which have not received their past week's rewards
        if (tokenAddress == address(rewardToken)) {
            uint256 currentBalance = rewardToken.balanceOf(address(this));
            // The amount distributed till the end is `rate * WEEK / (1 - RATE_REDUCTION_FACTOR)` where
            // `RATE_REDUCTION_FACTOR = BASE / RATE_REDUCTION_COEFFICIENT` which translates to:
            require(
                currentBalance >=
                    ((rate * RATE_REDUCTION_COEFFICIENT) * WEEK) / (RATE_REDUCTION_COEFFICIENT - BASE) + amount,
                "4"
            );
        }
        IERC20(tokenAddress).safeTransfer(to, amount);
        emit Recovered(tokenAddress, to, amount);
    }

    /// @notice Sets a new gauge controller
    /// @param _controller Address of the new gauge controller
    function setGaugeController(address _controller) external onlyRole(GOVERNOR_ROLE) {
        require(_controller != address(0), "0");
        controller = IGaugeController(_controller);
        emit GaugeControllerUpdated(_controller);
    }

    /// @notice Sets a new delegate gauge for pulling rewards of a type >= 2 gauges or of all type >= 2 gauges
    /// @param gaugeAddr Gauge to change the delegate of
    /// @param _delegateGauge Address of the new gauge delegate related to `gaugeAddr`
    /// @param toggleInterface Whether we should toggle the fact that the `_delegateGauge` is built for automation or not
    /// @dev This function can be used to remove delegating or introduce the pulling of rewards to a given address
    /// @dev If `gaugeAddr` is the zero address, this function updates the delegate gauge common to all gauges with type >= 2
    /// @dev The `toggleInterface` parameter has been added for convenience to save one transaction when adding a gauge delegate
    /// which supports the `notifyReward` interface
    function setDelegateGauge(
        address gaugeAddr,
        address _delegateGauge,
        bool toggleInterface
    ) external onlyRole(GOVERNOR_ROLE) {
        if (gaugeAddr != address(0)) {
            delegateGauges[gaugeAddr] = _delegateGauge;
        } else {
            delegateGauge = _delegateGauge;
        }
        emit DelegateGaugeUpdated(gaugeAddr, _delegateGauge);

        if (toggleInterface) {
            _toggleInterfaceKnown(_delegateGauge);
        }
    }

    /// @notice Changes the ANGLE emission rate
    /// @param _newRate New ANGLE emission rate
    /// @dev It is important to be super wary when calling this function and to make sure that `distributeReward`
    /// has been called for all gauges in the past weeks. If not, gauges may get an incorrect distribution of ANGLE rewards
    /// for these past weeks based on the new rate and not on the old rate
    /// @dev Governance should thus make sure to call this function rarely and when it does to do it after the weekly `distributeReward`
    /// calls for all existing gauges
    /// @dev As this function assumes that `distributeReward` has been called during the week, it also assumes that the `startEpochSupply`
    /// parameter has been put up to date
    function setRate(uint256 _newRate) external onlyRole(GOVERNOR_ROLE) {
        // Checking if the new rate is compatible with the amount of ANGLE tokens this contract has in balance
        // This check assumes, like this function, that `distributeReward` has correctly been called before
        require(
            rewardToken.balanceOf(address(this)) >=
                ((_newRate * RATE_REDUCTION_COEFFICIENT) * WEEK) / (RATE_REDUCTION_COEFFICIENT - BASE),
            "4"
        );
        rate = _newRate;
        emit RateUpdated(_newRate);
    }

    /// @notice Toggles the status of a gauge to either killed or unkilled
    /// @param gaugeAddr Gauge to toggle the status of
    /// @dev It is impossible to kill a gauge in the `GaugeController` contract, for this reason killing of gauges
    /// takes place in the `AngleDistributor` contract
    /// @dev This means that people could vote for a gauge in the gauge controller contract but that rewards are not going
    /// to be distributed to it in the end: people would need to remove their weights on the gauge killed to end the diminution
    /// in rewards
    /// @dev In the case of a gauge being killed, this function resets the timestamps at which this gauge has been approved and
    /// disapproves the gauge to spend the token
    /// @dev It should be cautiously called by governance as it could result in less ANGLE overall rewards than initially planned
    /// if people do not remove their voting weights to the killed gauge
    function toggleGauge(address gaugeAddr) external onlyRole(GOVERNOR_ROLE) {
        bool gaugeKilledMem = killedGauges[gaugeAddr];
        if (!gaugeKilledMem) {
            delete lastTimeGaugePaid[gaugeAddr];
            rewardToken.safeApprove(gaugeAddr, 0);
        }
        killedGauges[gaugeAddr] = !gaugeKilledMem;
        emit GaugeToggled(gaugeAddr, !gaugeKilledMem);
    }

    // ========================= Guardian Function =================================

    /// @notice Halts or activates distribution of rewards
    function toggleDistributions() external onlyRole(GUARDIAN_ROLE) {
        bool distributionsOnMem = distributionsOn;
        distributionsOn = !distributionsOnMem;
        emit DistributionsToggled(!distributionsOnMem);
    }

    /// @notice Notifies that the interface of a gauge delegate is known or has changed
    /// @param _delegateGauge Address of the gauge to change
    /// @dev Gauge delegates that are built for automation should be toggled
    function toggleInterfaceKnown(address _delegateGauge) external onlyRole(GUARDIAN_ROLE) {
        _toggleInterfaceKnown(_delegateGauge);
    }
}
