// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RewardController — Multi-Pool SPEC Reward Distributor
/// @notice Distributes SPEC token rewards across staking pools
/// @dev Based on Synthetix StakingRewards pattern with per-pool rates
///
/// Architecture:
///   - Owner creates reward pools (staking, LP, vault)
///   - Each pool has independent reward rate and period
///   - Users stake pool-specific tokens → earn SPEC rewards
///   - rewardPerToken accumulation tracks fair distribution
///
/// @custom:security-contact security@spectra.finance

interface ISpectraTokenRC {
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStakingTokenRC {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract RewardController {
    ISpectraTokenRC public immutable spectraToken;

    address public owner;

    struct PoolInfo {
        address stakingToken;
        uint256 rewardRate; // SPEC per second
        uint256 periodStart;
        uint256 periodEnd;
        uint256 lastUpdateTime;
        uint256 accRewardPerShare; // Accumulated reward per staked token (scaled 1e18)
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt; // Reward debt (accRewardPerShare at last interaction)
    }

    PoolInfo[] public pools;
    mapping(uint256 => mapping(address => UserInfo)) public users;

    /// @notice Pending unclaimed rewards per user
    mapping(address => uint256) public pendingHarvest;

    event PoolCreated(uint256 indexed poolId, address stakingToken, uint256 rewardRate);
    event Deposited(uint256 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 indexed poolId, uint256 newRate, uint256 duration);

    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error PoolNotFound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spectraToken) {
        spectraToken = ISpectraTokenRC(_spectraToken);
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────
    // Pool Management
    // ─────────────────────────────────────────────────────────────

    function createPool(address stakingToken, uint256 rewardRate, uint256 duration)
        external
        onlyOwner
        returns (uint256 poolId)
    {
        poolId = pools.length;
        pools.push(
            PoolInfo({
                stakingToken: stakingToken,
                rewardRate: rewardRate,
                periodStart: block.timestamp,
                periodEnd: block.timestamp + duration,
                lastUpdateTime: block.timestamp,
                accRewardPerShare: 0,
                totalStaked: 0
            })
        );

        emit PoolCreated(poolId, stakingToken, rewardRate);
    }

    /// @notice Update reward rate for a pool
    /// @dev V-08 VULNERABILITY: Does NOT accrue pending rewards before changing rate.
    ///      Any rewards accumulated since lastUpdateTime at the OLD rate are lost
    ///      forever. They remain unminted and no staker can ever claim them.
    ///      The correct implementation would call _updatePool(poolId) first to
    ///      settle all pending rewards, THEN change the rate.
    function notifyRewardAmount(uint256 poolId, uint256 newRewardRate, uint256 duration) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound();

        PoolInfo storage pool = pools[poolId];

        // BUG: Overwrites rate without settling pending rewards
        // Missing: _updatePool(poolId);
        pool.rewardRate = newRewardRate;
        pool.periodStart = block.timestamp;
        pool.periodEnd = block.timestamp + duration;
        pool.lastUpdateTime = block.timestamp;

        emit RewardRateUpdated(poolId, newRewardRate, duration);
    }

    // ─────────────────────────────────────────────────────────────
    // User Operations
    // ─────────────────────────────────────────────────────────────

    function deposit(uint256 poolId, uint256 amount) external {
        if (poolId >= pools.length) revert PoolNotFound();
        if (amount == 0) revert ZeroAmount();

        _updatePool(poolId);

        PoolInfo storage pool = pools[poolId];
        UserInfo storage user = users[poolId][msg.sender];

        // Harvest pending rewards before state change
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare / 1e18) - user.rewardDebt;
            if (pending > 0) {
                pendingHarvest[msg.sender] += pending;
            }
        }

        IStakingTokenRC(pool.stakingToken).transferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        pool.totalStaked += amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / 1e18;

        emit Deposited(poolId, msg.sender, amount);
    }

    function withdraw(uint256 poolId, uint256 amount) external {
        if (poolId >= pools.length) revert PoolNotFound();

        _updatePool(poolId);

        PoolInfo storage pool = pools[poolId];
        UserInfo storage user = users[poolId][msg.sender];

        if (user.amount < amount) revert InsufficientBalance();

        // Harvest pending rewards
        uint256 pending = (user.amount * pool.accRewardPerShare / 1e18) - user.rewardDebt;
        if (pending > 0) {
            pendingHarvest[msg.sender] += pending;
        }

        user.amount -= amount;
        pool.totalStaked -= amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / 1e18;

        IStakingTokenRC(pool.stakingToken).transfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    /// @notice Claim all accumulated SPEC rewards
    function claimRewards() external {
        uint256 totalPending = pendingHarvest[msg.sender];

        // Also check all pools for unclaimed
        for (uint256 i = 0; i < pools.length; i++) {
            _updatePool(i);
            UserInfo storage user = users[i][msg.sender];
            if (user.amount > 0) {
                uint256 pending = (user.amount * pools[i].accRewardPerShare / 1e18) - user.rewardDebt;
                totalPending += pending;
                user.rewardDebt = user.amount * pools[i].accRewardPerShare / 1e18;
            }
        }

        pendingHarvest[msg.sender] = 0;

        if (totalPending > 0) {
            spectraToken.mint(msg.sender, totalPending);
            emit RewardClaimed(msg.sender, totalPending);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────

    function _updatePool(uint256 poolId) internal {
        PoolInfo storage pool = pools[poolId];

        if (block.timestamp <= pool.lastUpdateTime) return;
        if (pool.totalStaked == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 endTime = block.timestamp < pool.periodEnd ? block.timestamp : pool.periodEnd;
        if (endTime <= pool.lastUpdateTime) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 elapsed = endTime - pool.lastUpdateTime;
        uint256 reward = pool.rewardRate * elapsed;
        pool.accRewardPerShare += reward * 1e18 / pool.totalStaked;
        pool.lastUpdateTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function pendingReward(uint256 poolId, address account) external view returns (uint256) {
        PoolInfo storage pool = pools[poolId];
        UserInfo storage user = users[poolId][account];

        uint256 accReward = pool.accRewardPerShare;
        if (block.timestamp > pool.lastUpdateTime && pool.totalStaked > 0) {
            uint256 endTime = block.timestamp < pool.periodEnd ? block.timestamp : pool.periodEnd;
            if (endTime > pool.lastUpdateTime) {
                uint256 elapsed = endTime - pool.lastUpdateTime;
                accReward += pool.rewardRate * elapsed * 1e18 / pool.totalStaked;
            }
        }

        return (user.amount * accReward / 1e18) - user.rewardDebt + pendingHarvest[account];
    }
}
