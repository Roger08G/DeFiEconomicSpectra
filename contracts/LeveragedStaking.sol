// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISpETH.sol";
import "./interfaces/ILiquidStaking.sol";

/// @title LeveragedStaking — Leveraged spETH Positions with ETH Liquidity Pool
/// @notice Users deposit spETH as collateral to borrow ETH, enabling leverage loops
/// @dev ETH liquidity is provided by passive LPs who earn interest on borrows
///
/// Architecture:
///   - Liquidity Providers deposit ETH → earn borrowing interest
///   - Leveragers deposit spETH as collateral → borrow ETH
///   - Max LTV: 75% (collateral value must cover 133% of debt)
///   - Liquidation at 85% LTV with 5% liquidation bonus
///   - closePosition() repays debt and returns collateral
///
/// Leverage flow:
///   1. Deposit spETH → borrow ETH → stake ETH for more spETH → repeat
///   2. To unwind: close position → repay debt → receive remaining collateral
///
/// @custom:security-contact security@spectra.finance

contract LeveragedStaking {
    ISpETH public immutable spETH;
    ILiquidStaking public immutable liquidStaking;

    address public owner;

    /// @notice Maximum loan-to-value ratio (basis points)
    uint256 public constant MAX_LTV_BPS = 7500; // 75%
    /// @notice Liquidation LTV threshold (basis points)
    uint256 public constant LIQUIDATION_LTV_BPS = 8500; // 85%
    /// @notice Liquidation bonus (basis points)
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Borrowing interest rate per second (scaled 1e18)
    /// ~5% APR = 5e16 / 365.25 / 86400 ≈ 1.585e9
    uint256 public borrowRatePerSecond = 1_585_489_600;

    struct Position {
        uint256 collateral; // spETH deposited as collateral
        uint256 debt; // ETH owed
        uint256 lastAccrual; // Timestamp of last interest accrual
    }

    mapping(address => Position) public positions;

    /// @notice Total spETH collateral held
    uint256 public totalCollateral;
    /// @notice Total ETH borrowed
    uint256 public totalBorrowed;
    /// @notice Total ETH deposited by liquidity providers
    uint256 public totalLiquidityDeposited;

    /// @notice LP share tracking
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;

    event CollateralDeposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event PositionClosed(address indexed user, uint256 collateral, uint256 debt, uint256 surplus);
    event Liquidated(address indexed user, address indexed liquidator, uint256 collateral, uint256 debt);
    event LiquidityDeposited(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityWithdrawn(address indexed provider, uint256 amount, uint256 shares);

    error Unauthorized();
    error ZeroAmount();
    error ExceedsLTV();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error PositionHealthy();
    error PositionUnderwater();
    error NoPosition();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spETH, address _liquidStaking) {
        spETH = ISpETH(_spETH);
        liquidStaking = ILiquidStaking(_liquidStaking);
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────
    // Liquidity Providers
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit ETH as a liquidity provider (earns borrowing interest)
    function depositLiquidity() external payable {
        if (msg.value == 0) revert ZeroAmount();

        uint256 shares;
        if (totalLpShares == 0) {
            shares = msg.value;
        } else {
            shares = msg.value * totalLpShares / totalLiquidityDeposited;
        }

        lpShares[msg.sender] += shares;
        totalLpShares += shares;
        totalLiquidityDeposited += msg.value;

        emit LiquidityDeposited(msg.sender, msg.value, shares);
    }

    /// @notice Withdraw ETH liquidity (if available)
    function withdrawLiquidity(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        if (lpShares[msg.sender] < shares) revert InsufficientCollateral();

        uint256 ethAmount = shares * totalLiquidityDeposited / totalLpShares;
        if (ethAmount > availableLiquidity()) revert InsufficientLiquidity();

        lpShares[msg.sender] -= shares;
        totalLpShares -= shares;
        totalLiquidityDeposited -= ethAmount;

        (bool sent,) = msg.sender.call{value: ethAmount}("");
        if (!sent) revert TransferFailed();

        emit LiquidityWithdrawn(msg.sender, ethAmount, shares);
    }

    // ─────────────────────────────────────────────────────────────
    // Leveraged Positions
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit spETH as collateral for a leveraged position
    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        spETH.transferFrom(msg.sender, address(this), amount);

        Position storage pos = positions[msg.sender];
        _accrueInterest(pos);
        pos.collateral += amount;
        totalCollateral += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Borrow ETH against deposited spETH collateral
    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = positions[msg.sender];
        if (pos.collateral == 0) revert InsufficientCollateral();
        _accrueInterest(pos);

        uint256 collateralValue = pos.collateral * _getExchangeRate() / 1e18;
        uint256 maxBorrow = collateralValue * MAX_LTV_BPS / BPS_DENOMINATOR;
        if (pos.debt + amount > maxBorrow) revert ExceedsLTV();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        pos.debt += amount;
        totalBorrowed += amount;

        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Borrowed(msg.sender, amount);
    }

    /// @notice Close a leveraged position — repay debt and reclaim collateral
    /// @dev V-01 VULNERABILITY (CRITICAL): Cross-function reentrancy.
    ///      This function sends ETH surplus to the user BEFORE clearing the
    ///      position state. During the ETH transfer, if the user is a contract,
    ///      their receive()/fallback() can re-enter borrow(), which reads the
    ///      still-populated pos.collateral and allows borrowing additional ETH.
    ///      When closePosition() resumes, it uses `delete positions[msg.sender]`
    ///      which overwrites the new debt from the reentrant borrow(), erasing it.
    ///      The attacker extracts borrowed ETH that becomes unrecoverable bad debt.
    function closePosition() external payable {
        Position storage pos = positions[msg.sender];
        if (pos.collateral == 0) revert NoPosition();
        _accrueInterest(pos);

        uint256 collateralAmount = pos.collateral;
        uint256 debtAmount = pos.debt;

        // User must send enough ETH to cover debt
        if (debtAmount > 0) {
            if (msg.value < debtAmount) revert InsufficientLiquidity();
        }

        uint256 surplus = msg.value - debtAmount;

        // Return ETH surplus BEFORE clearing state — REENTRANCY VULNERABILITY
        // An attacker's receive() function can call borrow() here.
        // At this point, pos.collateral and pos.debt are still the ORIGINAL values.
        if (surplus > 0) {
            (bool sent,) = msg.sender.call{value: surplus}("");
            if (!sent) revert TransferFailed();
        }

        // State update AFTER external call — reentrant borrow() changes are erased
        delete positions[msg.sender];
        totalCollateral -= collateralAmount;
        totalBorrowed -= debtAmount;

        // Return spETH collateral to user
        spETH.transfer(msg.sender, collateralAmount);

        emit PositionClosed(msg.sender, collateralAmount, debtAmount, surplus);
    }

    // ─────────────────────────────────────────────────────────────
    // Liquidation
    // ─────────────────────────────────────────────────────────────

    /// @notice Liquidate an unhealthy position
    function liquidate(address borrower) external payable {
        Position storage pos = positions[borrower];
        if (pos.collateral == 0) revert NoPosition();
        _accrueInterest(pos);

        uint256 collateralValue = pos.collateral * _getExchangeRate() / 1e18;
        uint256 currentLtv = pos.debt * BPS_DENOMINATOR / collateralValue;
        if (currentLtv < LIQUIDATION_LTV_BPS) revert PositionHealthy();

        // Liquidator repays debt
        if (msg.value < pos.debt) revert InsufficientLiquidity();

        uint256 bonus = pos.collateral * LIQUIDATION_BONUS_BPS / BPS_DENOMINATOR;
        uint256 collateralToLiquidator = pos.collateral + bonus;

        // Cap to available collateral
        if (collateralToLiquidator > pos.collateral) {
            collateralToLiquidator = pos.collateral;
        }

        uint256 debtRepaid = pos.debt;
        totalBorrowed -= debtRepaid;
        totalCollateral -= pos.collateral;

        delete positions[borrower];

        // Transfer spETH collateral to liquidator
        spETH.transfer(msg.sender, collateralToLiquidator);

        // Return excess ETH to liquidator
        uint256 excess = msg.value - debtRepaid;
        if (excess > 0) {
            (bool sent,) = msg.sender.call{value: excess}("");
            if (!sent) revert TransferFailed();
        }

        emit Liquidated(borrower, msg.sender, collateralToLiquidator, debtRepaid);
    }

    // ─────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────

    function _accrueInterest(Position storage pos) internal {
        if (pos.debt > 0 && pos.lastAccrual > 0) {
            uint256 elapsed = block.timestamp - pos.lastAccrual;
            uint256 interest = pos.debt * borrowRatePerSecond * elapsed / 1e18;
            pos.debt += interest;
            totalBorrowed += interest;
            totalLiquidityDeposited += interest; // Interest goes to LPs
        }
        pos.lastAccrual = block.timestamp;
    }

    function _getExchangeRate() internal view returns (uint256) {
        return liquidStaking.exchangeRate();
    }

    function availableLiquidity() public view returns (uint256) {
        return address(this).balance;
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    function getPosition(address user)
        external
        view
        returns (uint256 collateral, uint256 debt, uint256 collateralValue, uint256 currentLtv)
    {
        Position storage pos = positions[user];
        collateral = pos.collateral;
        debt = pos.debt;
        collateralValue = pos.collateral * _getExchangeRate() / 1e18;
        currentLtv = collateralValue > 0 ? debt * BPS_DENOMINATOR / collateralValue : 0;
    }

    function isLiquidatable(address user) external view returns (bool) {
        Position storage pos = positions[user];
        if (pos.collateral == 0) return false;
        uint256 collateralValue = pos.collateral * _getExchangeRate() / 1e18;
        if (collateralValue == 0) return true;
        return pos.debt * BPS_DENOMINATOR / collateralValue >= LIQUIDATION_LTV_BPS;
    }

    receive() external payable {
        // Accept ETH from borrowers repaying or LPs depositing
    }
}
