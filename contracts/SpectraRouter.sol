// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISpETH.sol";
import "./interfaces/ILiquidStaking.sol";
import "./interfaces/IYieldVault.sol";

/// @title SpectraRouter — Multi-Step Operation Router
/// @notice Convenience contract for common multi-contract operations
/// @dev Reduces multi-tx flows to single-tx for better UX
///
/// Common routes:
///   - stakeThenDeposit: ETH → LiquidStaking → YieldVault (one tx)
///   - stakeThenLeverage: ETH → LiquidStaking → LeveragedStaking (one tx)
///   - withdrawThenUnstake: YieldVault → LiquidStaking → ETH (one tx)
///
/// @custom:security-contact security@spectra.finance

interface ILeveragedStakingRouter {
    function depositCollateral(uint256 amount) external;
    function borrow(uint256 amount) external;
}

contract SpectraRouter {
    ISpETH public immutable spETH;
    ILiquidStaking public immutable liquidStaking;
    IYieldVault public immutable yieldVault;
    ILeveragedStakingRouter public immutable leveragedStaking;

    address public owner;

    /// @notice Track stranded tokens for rescue
    mapping(address => uint256) public strandedBalances;

    event RouteExecuted(address indexed user, string route, uint256 inputAmount, uint256 outputAmount);
    event StrandedTokensRescued(address indexed token, uint256 amount);

    error ZeroAmount();
    error InsufficientOutput();
    error TransferFailed();
    error Unauthorized();

    constructor(address _spETH, address _liquidStaking, address _yieldVault, address _leveragedStaking) {
        spETH = ISpETH(_spETH);
        liquidStaking = ILiquidStaking(_liquidStaking);
        yieldVault = IYieldVault(_yieldVault);
        leveragedStaking = ILeveragedStakingRouter(_leveragedStaking);
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────
    // Route: ETH → Stake → Vault Deposit
    // ─────────────────────────────────────────────────────────────

    /// @notice Stake ETH and deposit resulting spETH into YieldVault in one tx
    /// @param minShares Minimum vault shares to accept (slippage protection)
    /// @dev V-06 VULNERABILITY: Uses msg.value for the vault deposit amount
    ///      instead of the actual spETH received from staking.
    ///      When exchangeRate != 1:1, msg.value ≠ spETHReceived.
    ///      - If rate > 1 (spETH worth more): spETHReceived < msg.value.
    ///        vault.deposit(msg.value) tries to deposit MORE than available →
    ///        pulls from any spETH previously stranded in the router, or reverts.
    ///      - If rate < 1 (spETH worth less): spETHReceived > msg.value.
    ///        vault.deposit(msg.value) deposits LESS than received →
    ///        leftover spETH stranded in router, extractable by anyone.
    function stakeThenDeposit(uint256 minShares) external payable returns (uint256 vaultShares) {
        if (msg.value == 0) revert ZeroAmount();

        // Step 1: Stake ETH → get spETH
        uint256 spETHReceived = liquidStaking.stake{value: msg.value}();

        // Step 2: Approve vault
        spETH.approve(address(yieldVault), spETHReceived);

        // Step 3: Deposit into vault
        // BUG: Uses msg.value (ETH amount) instead of spETHReceived (spETH amount)
        vaultShares = yieldVault.deposit(msg.value);

        if (vaultShares < minShares) revert InsufficientOutput();

        emit RouteExecuted(msg.sender, "stakeThenDeposit", msg.value, vaultShares);
    }

    // ─────────────────────────────────────────────────────────────
    // Route: ETH → Stake → Leverage Collateral
    // ─────────────────────────────────────────────────────────────

    /// @notice Stake ETH and deposit spETH as leverage collateral in one tx
    function stakeThenLeverage() external payable {
        if (msg.value == 0) revert ZeroAmount();

        // Step 1: Stake ETH → get spETH
        uint256 spETHReceived = liquidStaking.stake{value: msg.value}();

        // Step 2: Approve leverage contract
        spETH.approve(address(leveragedStaking), spETHReceived);

        // Step 3: Deposit as collateral (correct — uses actual amount)
        leveragedStaking.depositCollateral(spETHReceived);

        emit RouteExecuted(msg.sender, "stakeThenLeverage", msg.value, spETHReceived);
    }

    // ─────────────────────────────────────────────────────────────
    // Route: Vault Withdraw → Unstake → ETH
    // ─────────────────────────────────────────────────────────────

    /// @notice Withdraw from vault and unstake spETH for ETH in one tx
    function withdrawThenUnstake(uint256 vaultShares, uint256 minETH) external returns (uint256 ethReceived) {
        if (vaultShares == 0) revert ZeroAmount();

        // Step 1: Withdraw from vault → get spETH
        uint256 spETHReceived = yieldVault.withdraw(vaultShares);

        // Step 2: Approve LiquidStaking
        spETH.approve(address(liquidStaking), spETHReceived);

        // Step 3: Unstake spETH → get ETH
        ethReceived = liquidStaking.withdraw(spETHReceived);

        if (ethReceived < minETH) revert InsufficientOutput();

        // Step 4: Send ETH to user
        (bool sent,) = msg.sender.call{value: ethReceived}("");
        if (!sent) revert TransferFailed();

        emit RouteExecuted(msg.sender, "withdrawThenUnstake", vaultShares, ethReceived);
    }

    // ─────────────────────────────────────────────────────────────
    // Route: Leverage Loop (stake → collateral → borrow → stake → collateral)
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute a single leverage loop iteration
    function leverageLoop(uint256 borrowAmount) external payable {
        if (msg.value == 0) revert ZeroAmount();

        // Stake ETH
        uint256 spETHReceived = liquidStaking.stake{value: msg.value}();

        // Deposit as collateral
        spETH.approve(address(leveragedStaking), spETHReceived);
        leveragedStaking.depositCollateral(spETHReceived);

        // Borrow ETH
        if (borrowAmount > 0) {
            leveragedStaking.borrow(borrowAmount);
            // Borrowed ETH stays in this contract for next loop
        }

        emit RouteExecuted(msg.sender, "leverageLoop", msg.value, spETHReceived);
    }

    // ─────────────────────────────────────────────────────────────
    // Rescue
    // ─────────────────────────────────────────────────────────────

    /// @notice Rescue stranded spETH tokens from router (open to anyone)
    function rescueSpETH() external {
        uint256 balance = spETH.balanceOf(address(this));
        if (balance > 0) {
            spETH.transfer(msg.sender, balance);
            emit StrandedTokensRescued(address(spETH), balance);
        }
    }

    receive() external payable {
        // Accept ETH from LiquidStaking withdrawals and leverage borrows
    }
}
