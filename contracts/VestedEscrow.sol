// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VestedEscrow — Vote-Escrowed SPEC Locking for Governance
/// @notice Lock SPEC tokens for governance voting power (veSpec model)
/// @dev Inspired by Curve's veCRV — voting power decays linearly with time
///
/// Architecture:
///   - Users lock SPEC for 1-52 weeks (MAX_LOCK_DURATION)
///   - Voting power = amount * remaining_time / MAX_LOCK_DURATION
///   - Locks can be extended or merged
///   - Early exit incurs a penalty proportional to remaining lock time
///
/// @custom:security-contact security@spectra.finance

interface ISpectraTokenVE {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract VestedEscrow {
    ISpectraTokenVE public immutable spectraToken;

    address public owner;
    address public penaltyCollector;

    /// @notice Maximum lock duration: 52 weeks
    uint256 public constant MAX_LOCK_DURATION = 52 weeks;
    /// @notice Minimum lock duration: 1 week
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;

    struct Lock {
        uint256 amount; // Current total locked amount
        uint256 originalAmount; // Amount at lock creation (for penalty calc)
        uint64 lockStart;
        uint64 lockEnd;
    }

    mapping(address => Lock) public locks;

    /// @notice Total SPEC locked across all users
    uint256 public totalLocked;

    /// @notice Total penalties collected
    uint256 public totalPenaltiesCollected;

    event Locked(address indexed user, uint256 amount, uint64 lockEnd);
    event Extended(address indexed user, uint64 newLockEnd);
    event Merged(address indexed user, uint256 additionalAmount);
    event EarlyExit(address indexed user, uint256 returned, uint256 penalty);
    event Withdrawn(address indexed user, uint256 amount);

    error Unauthorized();
    error ZeroAmount();
    error InvalidDuration();
    error LockExists();
    error NoLock();
    error LockNotExpired();
    error LockExpired();
    error CannotShorten();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spectraToken, address _penaltyCollector) {
        spectraToken = ISpectraTokenVE(_spectraToken);
        penaltyCollector = _penaltyCollector;
        owner = msg.sender;
    }

    function setPenaltyCollector(address _collector) external onlyOwner {
        penaltyCollector = _collector;
    }

    // ─────────────────────────────────────────────────────────────
    // Lock Management
    // ─────────────────────────────────────────────────────────────

    /// @notice Create a new lock position
    function lock(uint256 amount, uint64 duration) external {
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_LOCK_DURATION || duration > MAX_LOCK_DURATION) revert InvalidDuration();
        if (locks[msg.sender].amount > 0) revert LockExists();

        spectraToken.transferFrom(msg.sender, address(this), amount);

        locks[msg.sender] = Lock({
            amount: amount,
            originalAmount: amount,
            lockStart: uint64(block.timestamp),
            lockEnd: uint64(block.timestamp) + duration
        });

        totalLocked += amount;

        emit Locked(msg.sender, amount, uint64(block.timestamp) + duration);
    }

    /// @notice Extend lock duration (cannot shorten)
    function extendLock(uint64 newLockEnd) external {
        Lock storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NoLock();
        if (newLockEnd <= userLock.lockEnd) revert CannotShorten();
        if (newLockEnd > uint64(block.timestamp) + uint64(MAX_LOCK_DURATION)) revert InvalidDuration();

        userLock.lockEnd = newLockEnd;

        emit Extended(msg.sender, newLockEnd);
    }

    /// @notice Add more SPEC tokens to an existing lock
    /// @dev V-04 VULNERABILITY: originalAmount is NOT updated when merging.
    ///      The earlyExit() penalty is calculated based on originalAmount,
    ///      so merged tokens effectively bypass the penalty mechanism.
    ///      Example: lock 100 SPEC, merge 900 SPEC → total 1000 SPEC locked,
    ///      but penalty calculated on original 100 SPEC only.
    ///      Early exit at 50% through: penalty = 100*50% = 50, user gets 950.
    ///      Correct penalty would be: 1000*50% = 500, user should get 500.
    function merge(uint256 additionalAmount) external {
        if (additionalAmount == 0) revert ZeroAmount();

        Lock storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NoLock();
        if (block.timestamp >= userLock.lockEnd) revert LockExpired();

        spectraToken.transferFrom(msg.sender, address(this), additionalAmount);

        userLock.amount += additionalAmount;
        // BUG: originalAmount NOT updated — merged tokens escape penalty
        // Missing: userLock.originalAmount = userLock.amount;

        totalLocked += additionalAmount;

        emit Merged(msg.sender, additionalAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // Exit
    // ─────────────────────────────────────────────────────────────

    /// @notice Exit lock early with a penalty proportional to remaining time
    function earlyExit() external {
        Lock storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NoLock();
        if (block.timestamp >= userLock.lockEnd) revert LockExpired();

        uint256 timeRemaining = userLock.lockEnd - block.timestamp;
        uint256 totalDuration = userLock.lockEnd - userLock.lockStart;

        // Penalty = originalAmount * (timeRemaining / totalDuration)
        // BUG: Uses originalAmount, not current amount → merged tokens escape penalty
        uint256 penalty = userLock.originalAmount * timeRemaining / totalDuration;
        uint256 toReturn = userLock.amount - penalty;

        totalLocked -= userLock.amount;
        totalPenaltiesCollected += penalty;

        delete locks[msg.sender];

        if (toReturn > 0) {
            spectraToken.transfer(msg.sender, toReturn);
        }
        if (penalty > 0) {
            spectraToken.transfer(penaltyCollector, penalty);
        }

        emit EarlyExit(msg.sender, toReturn, penalty);
    }

    /// @notice Withdraw after lock has expired (no penalty)
    function withdraw() external {
        Lock storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NoLock();
        if (block.timestamp < userLock.lockEnd) revert LockNotExpired();

        uint256 amount = userLock.amount;
        totalLocked -= amount;

        delete locks[msg.sender];

        spectraToken.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────

    /// @notice Get voting power for a user
    /// @dev V-09 VULNERABILITY: Does NOT check if lock has expired.
    ///      After lockEnd, voting power should be 0, but this function
    ///      returns a constant value based on the original lock duration.
    ///      Expired-but-unwithdrawn locks retain full voting power forever,
    ///      diluting active governance participants.
    function votingPower(address account) external view returns (uint256) {
        Lock storage userLock = locks[account];
        if (userLock.amount == 0) return 0;

        // BUG: No expiry check — should return 0 if block.timestamp >= lockEnd
        // Missing: if (block.timestamp >= userLock.lockEnd) return 0;

        // Uses fixed lock duration instead of remaining time
        uint256 lockDuration = userLock.lockEnd - userLock.lockStart;
        return userLock.amount * lockDuration / MAX_LOCK_DURATION;
    }

    /// @notice Total voting power across all locked positions
    function totalVotingPower() external view returns (uint256 total) {
        // Note: In production this would use a checkpoint system.
        // Simplified for the scope of this contract.
        return totalLocked; // Simplified proxy
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    function getLock(address account)
        external
        view
        returns (uint256 amount, uint256 originalAmount, uint64 lockStart, uint64 lockEnd)
    {
        Lock storage l = locks[account];
        return (l.amount, l.originalAmount, l.lockStart, l.lockEnd);
    }

    function isLocked(address account) external view returns (bool) {
        return locks[account].amount > 0 && block.timestamp < locks[account].lockEnd;
    }

    function timeUntilUnlock(address account) external view returns (uint256) {
        Lock storage l = locks[account];
        if (l.amount == 0 || block.timestamp >= l.lockEnd) return 0;
        return l.lockEnd - block.timestamp;
    }
}
