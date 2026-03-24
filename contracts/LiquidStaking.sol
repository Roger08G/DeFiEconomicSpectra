// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISpETH.sol";
import "./interfaces/ILiquidStaking.sol";

/// @title LiquidStaking — Core ETH Staking Contract for Spectra Protocol
/// @notice Accepts ETH deposits and mints spETH (liquid staking derivative)
/// @dev Exchange rate: totalPooledETH / spETH.totalSupply()
///
/// Architecture:
///   - Users deposit ETH → receive spETH at current exchange rate
///   - Protocol operator can deploy ETH to yield strategies
///   - Rewards oracle reports earned yield, increasing exchange rate
///   - Users can withdraw by burning spETH (instant if liquidity available)
///
/// @custom:security-contact security@spectra.finance

contract LiquidStaking is ILiquidStaking {
    ISpETH public immutable spETH;

    address public owner;
    address public operator;
    address public rewardsOracle;
    address public withdrawalQueue;

    /// @notice Total ETH managed by the protocol (liquid + deployed to strategies)
    uint256 public totalPooledETH;

    /// @notice ETH allocated to external strategies (tracked for accounting)
    uint256 public totalDeployedToStrategies;

    /// @notice Accumulated protocol-earned rewards (for YieldVault harvest)
    uint256 public pendingRewards;

    /// @notice Maximum ETH that can be deployed to strategies (basis points)
    uint256 public constant MAX_STRATEGY_ALLOCATION_BPS = 8000; // 80%

    /// @notice Minimum deposit amount
    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    event Staked(address indexed user, uint256 ethAmount, uint256 spETHMinted);
    event Withdrawn(address indexed user, uint256 spETHBurned, uint256 ethReturned);
    event RewardsReported(uint256 amount, uint256 newTotalPooled);
    event DeployedToStrategy(address indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(address indexed strategy, uint256 amount);

    error Unauthorized();
    error BelowMinimum();
    error ZeroAmount();
    error InsufficientLiquidity();
    error ExceedsStrategyAllocation();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spETH) {
        spETH = ISpETH(_spETH);
        owner = msg.sender;
        operator = msg.sender;
        rewardsOracle = msg.sender;
    }

    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    function setRewardsOracle(address _oracle) external onlyOwner {
        rewardsOracle = _oracle;
    }

    function setWithdrawalQueue(address _queue) external onlyOwner {
        withdrawalQueue = _queue;
    }

    // ─────────────────────────────────────────────────────────────
    // Core Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit ETH and receive spETH at the current exchange rate
    function stake() external payable override returns (uint256 spETHAmount) {
        if (msg.value < MIN_DEPOSIT) revert BelowMinimum();

        uint256 totalSpETH = spETH.totalSupply();

        if (totalSpETH == 0 || totalPooledETH == 0) {
            spETHAmount = msg.value; // 1:1 for first deposit
        } else {
            spETHAmount = msg.value * totalSpETH / totalPooledETH;
        }

        totalPooledETH += msg.value;
        spETH.mint(msg.sender, spETHAmount);

        emit Staked(msg.sender, msg.value, spETHAmount);
    }

    /// @notice Burn spETH and receive ETH at the current exchange rate
    /// @dev V-07 VULNERABILITY: Uses totalPooledETH (includes strategy-deployed ETH)
    ///      but contract may not hold enough liquid ETH. First withdrawers drain
    ///      available liquidity; later ones revert or get nothing.
    function withdraw(uint256 spETHAmount) external override returns (uint256 ethAmount) {
        if (spETHAmount == 0) revert ZeroAmount();

        uint256 totalSpETH = spETH.totalSupply();
        ethAmount = spETHAmount * totalPooledETH / totalSpETH;

        spETH.burn(msg.sender, spETHAmount);
        totalPooledETH -= ethAmount;

        // BUG: No check that address(this).balance >= ethAmount
        // If ETH is deployed to strategies, this contract may have insufficient
        // liquid ETH. Early withdrawers succeed, later ones face reverts.
        (bool sent,) = msg.sender.call{value: ethAmount}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(msg.sender, spETHAmount, ethAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // Exchange Rate
    // ─────────────────────────────────────────────────────────────

    /// @notice Current exchange rate: ETH per spETH (scaled by 1e18)
    function exchangeRate() external view override returns (uint256) {
        uint256 totalSpETH = spETH.totalSupply();
        if (totalSpETH == 0) return 1e18;
        return totalPooledETH * 1e18 / totalSpETH;
    }

    // ─────────────────────────────────────────────────────────────
    // Strategy Deployment
    // ─────────────────────────────────────────────────────────────

    /// @notice Deploy idle ETH to an external yield strategy
    function deployToStrategy(address strategy, uint256 amount) external override onlyOperator {
        if (amount == 0) revert ZeroAmount();
        uint256 maxDeployable = totalPooledETH * MAX_STRATEGY_ALLOCATION_BPS / 10000;
        if (totalDeployedToStrategies + amount > maxDeployable) revert ExceedsStrategyAllocation();

        totalDeployedToStrategies += amount;
        // totalPooledETH unchanged — ETH is still "managed" by protocol

        (bool sent,) = strategy.call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit DeployedToStrategy(strategy, amount);
    }

    /// @notice Recall ETH from a strategy (strategy must send ETH back)
    function recallFromStrategy(uint256 amount) external onlyOperator {
        if (amount > totalDeployedToStrategies) amount = totalDeployedToStrategies;
        totalDeployedToStrategies -= amount;
        emit WithdrawnFromStrategy(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Rewards Reporting
    // ─────────────────────────────────────────────────────────────

    /// @notice Oracle reports new staking rewards earned by the protocol
    function reportRewards(uint256 amount) external override {
        if (msg.sender != rewardsOracle && msg.sender != owner) revert Unauthorized();
        totalPooledETH += amount;
        pendingRewards += amount;
        emit RewardsReported(amount, totalPooledETH);
    }

    /// @notice Called by YieldVault to claim pending rewards (transfer spETH rewards)
    function claimRewards() external override returns (uint256) {
        uint256 rewards = pendingRewards;
        if (rewards == 0) return 0;
        pendingRewards = 0;

        // Mint spETH rewards to the caller (YieldVault)
        uint256 totalSpETH = spETH.totalSupply();
        uint256 spETHRewards = rewards * totalSpETH / totalPooledETH;
        if (spETHRewards > 0) {
            spETH.mint(msg.sender, spETHRewards);
        }
        return spETHRewards;
    }

    /// @notice Available liquid ETH (not deployed to strategies)
    function availableLiquidity() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        // Accept ETH from strategies returning funds
    }
}
