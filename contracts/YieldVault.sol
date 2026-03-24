// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISpETH.sol";
import "./interfaces/ILiquidStaking.sol";
import "./interfaces/IYieldVault.sol";

/// @title YieldVault — Auto-Compounding spETH Vault
/// @notice Deposits spETH, earns yield from staking rewards, auto-compounds
/// @dev ERC4626-inspired vault with deposit fees and performance fees
///
/// Architecture:
///   - Depositors receive vault shares proportional to their contribution
///   - harvest() claims rewards from LiquidStaking and compounds them
///   - 0.3% deposit fee on deposit() to discourage churning
///   - 10% performance fee on harvested yield
///
/// @custom:security-contact security@spectra.finance

contract YieldVault is IYieldVault {
    ISpETH public immutable spETH;
    ILiquidStaking public immutable liquidStaking;

    address public owner;
    address public feeRecipient;

    uint256 public totalManagedAssets;
    uint256 public totalShares;

    mapping(address => uint256) public shareBalanceOf;

    /// @notice Deposit fee: 30 basis points (0.3%)
    uint256 public constant DEPOSIT_FEE_BPS = 30;
    /// @notice Performance fee: 10% of harvested yield
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Last harvest timestamp
    uint256 public lastHarvestTime;

    /// @notice Total fees collected (accounting)
    uint256 public totalFeesCollected;

    event Deposited(address indexed user, uint256 assets, uint256 shares, uint256 fee);
    event Minted(address indexed user, uint256 shares, uint256 assets);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);
    event Harvested(uint256 harvested, uint256 performanceFee, uint256 newTotalAssets);

    error Unauthorized();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spETH, address _liquidStaking, address _feeRecipient) {
        spETH = ISpETH(_spETH);
        liquidStaking = ILiquidStaking(_liquidStaking);
        feeRecipient = _feeRecipient;
        owner = msg.sender;
        lastHarvestTime = block.timestamp;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    // ─────────────────────────────────────────────────────────────
    // Deposit / Mint / Withdraw
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit spETH and receive vault shares (subject to deposit fee)
    function deposit(uint256 assets) external override returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        // Apply deposit fee
        uint256 fee = assets * DEPOSIT_FEE_BPS / BPS_DENOMINATOR;
        uint256 netAssets = assets - fee;

        // Calculate shares
        if (totalShares == 0 || totalManagedAssets == 0) {
            shares = netAssets;
        } else {
            shares = netAssets * totalShares / totalManagedAssets;
        }
        if (shares == 0) revert ZeroShares();

        // Transfer spETH from user
        spETH.transferFrom(msg.sender, address(this), assets);

        // Send fee to recipient
        if (fee > 0) {
            spETH.transfer(feeRecipient, fee);
            totalFeesCollected += fee;
        }

        totalManagedAssets += netAssets;
        totalShares += shares;
        shareBalanceOf[msg.sender] += shares;

        emit Deposited(msg.sender, assets, shares, fee);
    }

    /// @notice Mint exact number of vault shares by providing required spETH
    /// @dev V-10 VULNERABILITY: This function does NOT charge the deposit fee.
    ///      Users can bypass the 0.3% deposit fee entirely by using mint()
    ///      instead of deposit(). The deposit fee is intended to discourage
    ///      churning and generate protocol revenue — this function circumvents it.
    function mint(uint256 shares) external override returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();

        // Calculate required assets — NO FEE APPLIED
        if (totalShares == 0 || totalManagedAssets == 0) {
            assets = shares;
        } else {
            assets = shares * totalManagedAssets / totalShares;
            if (assets == 0) assets = 1; // minimum 1 wei
        }

        spETH.transferFrom(msg.sender, address(this), assets);

        totalManagedAssets += assets;
        totalShares += shares;
        shareBalanceOf[msg.sender] += shares;

        emit Minted(msg.sender, shares, assets);
    }

    /// @notice Redeem vault shares for underlying spETH
    function withdraw(uint256 shares) external override returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (shareBalanceOf[msg.sender] < shares) revert InsufficientShares();

        assets = shares * totalManagedAssets / totalShares;

        shareBalanceOf[msg.sender] -= shares;
        totalShares -= shares;
        totalManagedAssets -= assets;

        spETH.transfer(msg.sender, assets);

        emit Withdrawn(msg.sender, shares, assets);
    }

    // ─────────────────────────────────────────────────────────────
    // Harvest (Compounding)
    // ─────────────────────────────────────────────────────────────

    /// @notice Harvest pending rewards and compound them into the vault
    /// @dev V-05 VULNERABILITY: No deposit timelock / cooldown period.
    ///      An attacker can sandwich this call:
    ///        1. Deposit large amount of spETH (getting shares at pre-harvest price)
    ///        2. Call harvest() — totalManagedAssets increases from yield
    ///        3. Withdraw immediately — shares now worth more (post-harvest price)
    ///      The attacker captures a disproportionate share of the yield without
    ///      having been staked during the yield-earning period.
    function harvest() external override {
        // Claim spETH rewards from LiquidStaking
        uint256 balanceBefore = spETH.balanceOf(address(this));
        liquidStaking.claimRewards();
        uint256 harvested = spETH.balanceOf(address(this)) - balanceBefore;

        if (harvested == 0) return;

        // Take performance fee
        uint256 fee = harvested * PERFORMANCE_FEE_BPS / BPS_DENOMINATOR;
        if (fee > 0) {
            spETH.transfer(feeRecipient, fee);
            totalFeesCollected += fee;
        }

        // Compound: remainder increases totalManagedAssets (raises share price)
        uint256 netHarvested = harvested - fee;
        totalManagedAssets += netHarvested;
        lastHarvestTime = block.timestamp;

        emit Harvested(harvested, fee, totalManagedAssets);
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    function sharePrice() external view override returns (uint256) {
        if (totalShares == 0) return 1e18;
        return totalManagedAssets * 1e18 / totalShares;
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        uint256 fee = assets * DEPOSIT_FEE_BPS / BPS_DENOMINATOR;
        uint256 netAssets = assets - fee;
        if (totalShares == 0 || totalManagedAssets == 0) return netAssets;
        return netAssets * totalShares / totalManagedAssets;
    }

    function previewWithdraw(uint256 shares) external view returns (uint256 assets) {
        if (totalShares == 0) return 0;
        return shares * totalManagedAssets / totalShares;
    }
}
