// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISpETH.sol";
import "./interfaces/ILiquidStaking.sol";

/// @title WithdrawalQueue — Time-Delayed ETH Withdrawal Queue
/// @notice Users queue spETH burn requests; processed after WITHDRAWAL_DELAY
/// @dev Provides orderly withdrawal process to prevent bank-run scenarios
///
/// Flow:
///   1. User calls requestWithdrawal(spETHAmount)
///   2. spETH is held in escrow
///   3. After WITHDRAWAL_DELAY, operator calls processWithdrawals()
///   4. User receives ETH at the current exchange rate
///
/// @custom:security-contact security@spectra.finance

contract WithdrawalQueue {
    ISpETH public immutable spETH;
    ILiquidStaking public immutable liquidStaking;

    address public owner;
    address public operator;

    uint256 public constant WITHDRAWAL_DELAY = 7 days;
    uint256 public constant MAX_BATCH_SIZE = 50;

    struct WithdrawalRequest {
        address requester;
        uint256 spETHAmount;
        uint256 requestTimestamp;
        // V-03 VULNERABILITY: No exchange rate snapshot at request time.
        // Rate is read at processing time, allowing front-running.
        bool processed;
        bool cancelled;
    }

    WithdrawalRequest[] public requests;
    uint256 public nextToProcess;
    uint256 public totalPendingSpETH;

    /// @notice Tracks total ETH sent per user (for accounting)
    mapping(address => uint256) public totalWithdrawn;

    event WithdrawalRequested(address indexed user, uint256 indexed requestId, uint256 spETHAmount);
    event WithdrawalProcessed(address indexed user, uint256 indexed requestId, uint256 ethAmount);
    event WithdrawalCancelled(address indexed user, uint256 indexed requestId);

    error Unauthorized();
    error ZeroAmount();
    error NotReady();
    error AlreadyProcessed();
    error RequestNotOwned();
    error TransferFailed();
    error NoRequestsToProcess();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spETH, address _liquidStaking) {
        spETH = ISpETH(_spETH);
        liquidStaking = ILiquidStaking(_liquidStaking);
        owner = msg.sender;
        operator = msg.sender;
    }

    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    // ─────────────────────────────────────────────────────────────
    // User Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Queue a withdrawal request — spETH is held in escrow
    function requestWithdrawal(uint256 spETHAmount) external returns (uint256 requestId) {
        if (spETHAmount == 0) revert ZeroAmount();

        // Transfer spETH to this contract (escrow)
        spETH.transferFrom(msg.sender, address(this), spETHAmount);
        totalPendingSpETH += spETHAmount;

        requestId = requests.length;
        requests.push(
            WithdrawalRequest({
                requester: msg.sender,
                spETHAmount: spETHAmount,
                requestTimestamp: block.timestamp,
                processed: false,
                cancelled: false
            })
        );

        emit WithdrawalRequested(msg.sender, requestId, spETHAmount);
    }

    /// @notice Cancel a pending withdrawal request (returns spETH)
    function cancelWithdrawal(uint256 requestId) external {
        WithdrawalRequest storage req = requests[requestId];
        if (req.requester != msg.sender) revert RequestNotOwned();
        if (req.processed || req.cancelled) revert AlreadyProcessed();

        req.cancelled = true;
        totalPendingSpETH -= req.spETHAmount;

        spETH.transfer(msg.sender, req.spETHAmount);

        emit WithdrawalCancelled(msg.sender, requestId);
    }

    // ─────────────────────────────────────────────────────────────
    // Queue Processing
    // ─────────────────────────────────────────────────────────────

    /// @notice Process pending withdrawal requests (operator or permissionless)
    /// @dev V-03 VULNERABILITY: Exchange rate is read at PROCESSING time, not
    ///      at request time. Between request and processing (7-day delay), the
    ///      rate can change significantly. Users who see upcoming rate increases
    ///      (e.g., pending reportRewards) can queue withdrawals to capture the
    ///      higher rate. Users who queue before rate drops get windfall at the
    ///      expense of the protocol.
    function processWithdrawals(uint256 count) external {
        if (nextToProcess >= requests.length) revert NoRequestsToProcess();
        if (count > MAX_BATCH_SIZE) count = MAX_BATCH_SIZE;

        // Read exchange rate NOW — not at request time
        uint256 currentRate = liquidStaking.exchangeRate();
        uint256 processed = 0;

        for (uint256 i = nextToProcess; i < requests.length && processed < count; i++) {
            WithdrawalRequest storage req = requests[i];

            if (req.cancelled) {
                nextToProcess = i + 1;
                continue;
            }

            if (req.processed) {
                nextToProcess = i + 1;
                continue;
            }

            // Check delay has elapsed
            if (block.timestamp < req.requestTimestamp + WITHDRAWAL_DELAY) {
                break; // Queue is ordered, so stop here
            }

            // Calculate ETH at CURRENT rate (vulnerability)
            uint256 ethAmount = req.spETHAmount * currentRate / 1e18;

            req.processed = true;
            totalPendingSpETH -= req.spETHAmount;
            totalWithdrawn[req.requester] += ethAmount;
            nextToProcess = i + 1;
            processed++;

            // Burn the escrowed spETH
            spETH.burn(address(this), req.spETHAmount);

            // Send ETH to the user
            (bool sent,) = req.requester.call{value: ethAmount}("");
            if (!sent) revert TransferFailed();

            emit WithdrawalProcessed(req.requester, i, ethAmount);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    function pendingRequestCount() external view returns (uint256) {
        return requests.length - nextToProcess;
    }

    function getRequest(uint256 id)
        external
        view
        returns (address requester, uint256 spETHAmount, uint256 requestTimestamp, bool processed, bool cancelled)
    {
        WithdrawalRequest storage req = requests[id];
        return (req.requester, req.spETHAmount, req.requestTimestamp, req.processed, req.cancelled);
    }

    function totalRequests() external view returns (uint256) {
        return requests.length;
    }

    receive() external payable {
        // Accept ETH from LiquidStaking for withdrawal fulfillment
    }
}
