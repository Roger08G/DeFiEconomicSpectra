// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BondingCurve — Spectra Token AMM with Virtual Liquidity
/// @notice Bancor-style bonding curve for SPEC token issuance and redemption
/// @dev Uses virtual reserves for initial liquidity bootstrapping
///
/// Architecture:
///   - Virtual reserve provides synthetic liquidity from genesis
///   - realReserve tracks actual ETH contributed by buyers
///   - Token price increases as supply grows (bonding curve mechanics)
///   - Anyone can buy SPEC with ETH or sell SPEC for ETH
///
/// @custom:security-contact security@spectra.finance

interface ISpectraTokenBC {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract BondingCurve {
    ISpectraTokenBC public immutable spectraToken;

    address public owner;

    /// @notice Actual ETH held in this contract from token sales
    uint256 public realReserve;

    /// @notice Virtual ETH reserve for liquidity bootstrapping
    /// @dev This creates synthetic depth so early buyers don't move price wildly
    uint256 public virtualReserve;

    /// @notice Total SPEC tokens issued through this bonding curve
    uint256 public tokenSupply;

    /// @notice Protocol fee on sells (basis points)
    uint256 public constant SELL_FEE_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum buy/sell amounts
    uint256 public constant MIN_BUY = 0.001 ether;
    uint256 public constant MIN_SELL = 1e15; // 0.001 SPEC

    /// @notice Whether trading is enabled
    bool public tradingEnabled;

    event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut);
    event TradingEnabled();

    error Unauthorized();
    error TradingDisabled();
    error BelowMinimum();
    error InsufficientReserves();
    error ZeroOutput();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _spectraToken, uint256 _virtualReserve, uint256 _initialSupply) {
        spectraToken = ISpectraTokenBC(_spectraToken);
        virtualReserve = _virtualReserve;
        tokenSupply = _initialSupply;
        owner = msg.sender;
        tradingEnabled = true;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    // ─────────────────────────────────────────────────────────────
    // Buy: ETH → SPEC
    // ─────────────────────────────────────────────────────────────

    /// @notice Buy SPEC tokens by sending ETH
    /// @dev Uses constant-product AMM formula with virtual reserves
    ///      tokensOut = supply * ethIn / (totalReserve + ethIn)
    function buy() external payable returns (uint256 tokensOut) {
        if (!tradingEnabled) revert TradingDisabled();
        if (msg.value < MIN_BUY) revert BelowMinimum();

        uint256 totalReserve = realReserve + virtualReserve;

        // Standard AMM constant-product formula (with virtual liquidity)
        tokensOut = tokenSupply * msg.value / (totalReserve + msg.value);
        if (tokensOut == 0) revert ZeroOutput();

        realReserve += msg.value;
        tokenSupply += tokensOut;

        spectraToken.mint(msg.sender, tokensOut);

        emit TokensBought(msg.sender, msg.value, tokensOut);
    }

    // ─────────────────────────────────────────────────────────────
    // Sell: SPEC → ETH
    // ─────────────────────────────────────────────────────────────

    /// @notice Sell SPEC tokens and receive ETH
    /// @dev V-02 VULNERABILITY: Uses SPOT PRICE instead of AMM curve integral.
    ///      buy() uses the correct constant-product formula (with price impact),
    ///      but sell() naively computes: ethOut = spotPrice * tokenAmount.
    ///      This means large sells receive MORE ETH than the curve should give,
    ///      because no price impact / slippage is applied on the sell side.
    ///      Over time, sellers extract more value than buyers contributed,
    ///      draining realReserve and leaving last sellers with nothing.
    function sell(uint256 tokenAmount) external returns (uint256 ethOut) {
        if (!tradingEnabled) revert TradingDisabled();
        if (tokenAmount < MIN_SELL) revert BelowMinimum();
        if (spectraToken.balanceOf(msg.sender) < tokenAmount) revert InsufficientReserves();

        // BUG: Compute spot price and use it linearly (no price impact!)
        // Correct would be: ethOut = totalReserve * tokenAmount / (tokenSupply + tokenAmount)
        uint256 totalReserve = realReserve + virtualReserve;
        uint256 currentSpotPrice = totalReserve * 1e18 / tokenSupply;
        ethOut = currentSpotPrice * tokenAmount / 1e18;

        // Apply sell fee
        uint256 fee = ethOut * SELL_FEE_BPS / BPS_DENOMINATOR;
        ethOut -= fee;

        if (ethOut > realReserve) revert InsufficientReserves();

        spectraToken.burn(msg.sender, tokenAmount);
        tokenSupply -= tokenAmount;
        realReserve -= ethOut;

        (bool sent,) = msg.sender.call{value: ethOut}("");
        if (!sent) revert TransferFailed();

        emit TokensSold(msg.sender, tokenAmount, ethOut);
    }

    // ─────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Current spot price of SPEC in ETH (scaled 1e18)
    function spotPrice() external view returns (uint256) {
        if (tokenSupply == 0) return 0;
        return (realReserve + virtualReserve) * 1e18 / tokenSupply;
    }

    /// @notice Preview how many tokens a given ETH amount would buy
    function previewBuy(uint256 ethAmount) external view returns (uint256) {
        uint256 totalReserve = realReserve + virtualReserve;
        return tokenSupply * ethAmount / (totalReserve + ethAmount);
    }

    /// @notice Preview how much ETH selling tokens would return
    function previewSell(uint256 tokenAmount) external view returns (uint256) {
        uint256 totalReserve = realReserve + virtualReserve;
        uint256 currentSpotPrice = totalReserve * 1e18 / tokenSupply;
        uint256 gross = currentSpotPrice * tokenAmount / 1e18;
        uint256 fee = gross * SELL_FEE_BPS / BPS_DENOMINATOR;
        return gross - fee;
    }

    /// @notice Total reserve including virtual
    function totalReserve() external view returns (uint256) {
        return realReserve + virtualReserve;
    }

    receive() external payable {
        // Accept ETH (for protocol top-ups if needed)
    }
}
