# Spectra Protocol — Liquid Restaking Derivatives + Leveraged Yield

> **Benchmark ID**: `defi_economic_invariant_4`
> **nSLOC**: ~1,700
> **Contracts**: 10 (+ 4 interfaces)
> **Planted Vulnerabilities**: 10 (2 Critical, 5 High, 3 Medium)


## Protocol Overview

**Spectra Protocol** is a liquid restaking infrastructure protocol for Ethereum. It enables users to stake ETH and receive `spETH` — a liquid staking derivative that represents their share of the protocol's staked ETH. spETH can be freely used across DeFi: deposited into auto-compounding yield vaults, used as collateral for leveraged staking positions, or traded via the protocol's bonding curve governance token (`SPEC`).

### Key Features
- **Liquid Staking**: Deposit ETH → receive spETH (1:1 at genesis, exchange rate appreciates with yield)
- **Auto-Compounding Vault**: Deposit spETH → earn compound yield automatically
- **Leveraged Restaking**: Use spETH as collateral → borrow ETH → restake for amplified yields
- **SPEC Governance Token**: Bonding curve AMM with virtual liquidity bootstrapping
- **Vote-Escrowed Governance**: Lock SPEC → veSpec → governance voting power
- **Multi-Pool Rewards**: SPEC token rewards distributed across staking pools
- **Withdrawal Queue**: Orderly 7-day delayed unstaking mechanism
- **Convenience Router**: One-click multi-step operations (stake+deposit, leverage loops)

### Protocol TVL Assumptions
- **Target TVL**: $50M+ at maturity
- **spETH/ETH exchange rate**: Starts at 1:1, appreciates ~5% APR from validator rewards
- **SPEC governance token**: Bonding curve with 100 ETH virtual reserve at genesis
- **Leverage**: Up to 3x via recursive staking loop

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         User / Frontend                         │
└──────────┬──────────┬──────────┬──────────┬──────────┬──────────┘
           │          │          │          │          │
    ┌──────▼──────┐   │   ┌──────▼──────┐   │   ┌──────▼──────┐
    │ SpectraRouter│   │   │BondingCurve │   │   │VestedEscrow │
    │  (multi-op) │   │   │ (SPEC AMM)  │   │   │  (veSpec)   │
    └──────┬──────┘   │   └─────────────┘   │   └─────────────┘
           │          │                      │
    ┌──────▼──────────▼──────┐       ┌──────▼──────┐
    │    LiquidStaking       │       │  YieldVault │
    │  (ETH → spETH core)   │◄──────┤(auto-cpnd)  │
    └──────┬──────────┬──────┘       └─────────────┘
           │          │
    ┌──────▼──────┐ ┌─▼─────────────┐
    │ Withdrawal  │ │ Leveraged     │
    │ Queue       │ │ Staking       │
    │ (7d delay)  │ │ (borrow/lend) │
    └─────────────┘ └───────────────┘
           │
    ┌──────▼──────────────┐
    │  RewardController   │
    │ (multi-pool SPEC)   │
    └─────────────────────┘
```

### Token Contracts
| Token | Symbol | Purpose |
|-------|--------|---------|
| `SpectraToken.sol` | SPEC | Governance + utility token, mintable for rewards |
| `SpETH.sol` | spETH | Liquid staking derivative, mint/burn by LiquidStaking |

### Core Contracts
| Contract | Purpose |
|----------|---------|
| `LiquidStaking.sol` | Core staking: ETH deposits, spETH minting, strategy deployment |
| `WithdrawalQueue.sol` | Orderly queue-based unstaking with 7-day delay |
| `YieldVault.sol` | Auto-compounding vault for spETH with deposit & performance fees |
| `BondingCurve.sol` | SPEC token AMM with virtual reserve bootstrapping |
| `RewardController.sol` | Multi-pool SPEC reward distribution (Synthetix-style) |
| `VestedEscrow.sol` | Vote-escrowed SPEC locking for governance |
| `LeveragedStaking.sol` | ETH lending pool + leveraged spETH positions |
| `SpectraRouter.sol` | Multi-step convenience router for common operations |

### Interfaces
| Interface | Used By |
|-----------|---------|
| `ISpETH.sol` | LiquidStaking, YieldVault, WithdrawalQueue, LeveragedStaking, Router |
| `ILiquidStaking.sol` | WithdrawalQueue, YieldVault, LeveragedStaking, Router |
| `IYieldVault.sol` | Router |
| `IBondingCurve.sol` | (external integrations) |

---

## Vulnerability Catalog

### V-01 — Cross-Function Reentrancy in Leveraged Position Close (**Critical**)

| Field | Value |
|-------|-------|
| **Contract** | `LeveragedStaking.sol` |
| **Function** | `closePosition()` |
| **Category** | Reentrancy (cross-function) |
| **Impact** | Unbacked debt creation — attacker extracts ETH that becomes bad debt |

**Description**: `closePosition()` sends ETH surplus to the caller BEFORE clearing the position state via `delete positions[msg.sender]`. During the ETH transfer, an attacker contract's `receive()` function can re-enter `borrow()`, which reads the still-populated `pos.collateral` (not yet zeroed). The attacker borrows additional ETH against collateral they're closing. When `closePosition()` resumes, `delete positions[msg.sender]` overwrites the new debt from the reentrant call, effectively erasing it.

**Attack Vector**:
1. Attacker creates leverage position: deposit spETH, borrow ETH
2. Calls `closePosition()` sending enough ETH to cover debt
3. In `receive()` callback during surplus transfer, calls `borrow(additionalAmount)`
4. `borrow()` succeeds (collateral still exists in state)
5. `closePosition()` finishes with `delete` — erases all debt including the new borrow
6. Result: borrowed ETH is unrecoverable, creating bad debt for LP depositors

---

### V-02 — Bonding Curve Sell-Side Price Impact Asymmetry (**Critical**)

| Field | Value |
|-------|-------|
| **Contract** | `BondingCurve.sol` |
| **Function** | `sell()` |
| **Category** | AMM formula asymmetry |
| **Impact** | Reserve drain — sellers extract more ETH than contributed, insolvency |

**Description**: `buy()` uses the correct constant-product AMM formula (`supply * ethIn / (reserve + ethIn)`) which naturally applies price impact/slippage. However, `sell()` uses a naive spot-price multiplication (`spotPrice * tokenAmount`) with NO price impact. For large sells, this returns significantly more ETH than the curve integral should give. Over time, cumulative sell proceeds exceed the real ETH reserve, draining the bonding curve and leaving later sellers unable to exit.

**Attack Vector**:
1. Buy SPEC tokens with multiple small transactions (minimal slippage on buy)
2. Accumulate large SPEC position
3. Sell entire position in one transaction at spot price (no slippage penalty)
4. Receive disproportionate ETH — more than fair value per the curve
5. Remaining participants find realReserve depleted; their tokens are worth less

**Mathematical Impact**: Selling 50% of supply at spot price gives `reserve * 0.5`, while the correct AMM formula gives `reserve * 0.5 / 1.5 = reserve * 0.333`. The attacker extracts ~50% more ETH than they should.

---

### V-03 — Withdrawal Queue Rate-at-Processing Vulnerability (**High**)

| Field | Value |
|-------|-------|
| **Contract** | `WithdrawalQueue.sol` |
| **Function** | `processWithdrawals()` |
| **Category** | Stale price / front-running |
| **Impact** | Unfair exchange rate — early knowledge of rate changes enables arbitrage |

**Description**: When users queue a withdrawal, only the spETH amount is recorded — NOT the exchange rate at request time. The exchange rate is read from `liquidStaking.exchangeRate()` at PROCESSING time (7 days later). This means users who know a `reportRewards()` call (increasing the rate) is pending can queue withdrawals before the increase and get processed at the higher rate, capturing yield they didn't earn during the queuing period.

**Attack Vector**:
1. Monitor mempool for pending `reportRewards()` transactions
2. Front-run: queue withdrawal of spETH right before rewards posted
3. Wait 7 days for processing
4. Get processed at the new higher rate (post-rewards)
5. Profit: receive more ETH than the spETH was worth at queue time

---

### V-04 — VestedEscrow Merge Penalty Bypass (**High**)

| Field | Value |
|-------|-------|
| **Contract** | `VestedEscrow.sol` |
| **Function** | `merge()` → `earlyExit()` |
| **Category** | Accounting inconsistency |
| **Impact** | Early exit penalty evasion — bypasses 90%+ of intended penalty |

**Description**: `merge()` adds tokens to an existing lock but does NOT update `originalAmount`. The `earlyExit()` function calculates the penalty based on `originalAmount`, not the current `amount`. An attacker with a small initial lock can merge a much larger amount and then early-exit paying penalty only on the original small amount.

**Attack Vector**:
1. Lock 1 SPEC for 52 weeks (`originalAmount = 1`)
2. Merge 999 SPEC into the lock (`amount = 1000`, `originalAmount` still = 1)
3. Immediately `earlyExit()`: penalty ≈ 1 SPEC, receives ≈ 999 SPEC
4. Effectively locked 1000 SPEC for zero time with near-zero penalty
5. Can vote with full governance power during the brief lock period

---

### V-05 — YieldVault Harvest Sandwich Attack (**High**)

| Field | Value |
|-------|-------|
| **Contract** | `YieldVault.sol` |
| **Function** | `harvest()` + `deposit()` + `withdraw()` |
| **Category** | MEV / sandwich attack |
| **Impact** | Yield theft — attacker captures yield without being staked during earning period |

**Description**: `harvest()` increases `totalManagedAssets` when rewards are compounded. There is no deposit cooldown or timelock, so an attacker can deposit a large amount of spETH immediately before harvest (getting shares at pre-harvest price), then withdraw immediately after harvest (shares now worth more). The attacker captures a share of the harvested yield proportional to their briefly-held share, diluting returns for long-term depositors.

**Attack Vector**:
1. Monitor for pending `harvest()` transaction
2. Front-run: deposit large amount of spETH into YieldVault (cheap shares)
3. `harvest()` executes — `totalManagedAssets` increases, share price rises
4. Immediately withdraw — receive more spETH than deposited
5. Profit equals their share of the harvest minus the 0.3% deposit fee

---

### V-06 — Router Uses Wrong Variable for Vault Deposit (**High**)

| Field | Value |
|-------|-------|
| **Contract** | `SpectraRouter.sol` |
| **Function** | `stakeThenDeposit()` |
| **Category** | Variable confusion / logic error |
| **Impact** | Token stranding or unexpected reverts; extractable value via `rescueSpETH()` |

**Description**: `stakeThenDeposit()` calls `liquidStaking.stake{value: msg.value}()` which returns `spETHReceived`. It then calls `yieldVault.deposit(msg.value)` using the ETH input amount instead of the actual `spETHReceived`. When the exchange rate ≠ 1:1:
- **Rate > 1** (spETH appreciating): `spETHReceived < msg.value` → tries to deposit more than available → reverts OR consumes previously stranded tokens
- **Rate < 1**: `spETHReceived > msg.value` → deposits less → leftover stranded in router

**Attack Vector**:
1. Wait for exchange rate to diverge from 1:1 (naturally happens over time)
2. Users call `stakeThenDeposit()` with rate < 1 → leftover spETH stranded
3. Attacker calls `rescueSpETH()` to sweep all stranded tokens
4. Free spETH extracted from other users' transactions

---

### V-07 — LiquidStaking Withdrawal Insolvency (**High**)

| Field | Value |
|-------|-------|
| **Contract** | `LiquidStaking.sol` |
| **Function** | `withdraw()` |
| **Category** | Liquidity mismatch / bank run |
| **Impact** | Later withdrawers cannot exit — protocol insolvency |

**Description**: `withdraw()` computes `ethAmount = spETHAmount * totalPooledETH / totalSpETH`, which includes ETH deployed to strategies. But the contract may not hold that much liquid ETH. Early withdrawers drain the available balance; later withdrawers' transactions revert. The exchange rate appears healthy (total managed value) but actual liquidity is insufficient.

**Attack Vector**:
1. Observe that operator has deployed significant ETH to strategies
2. Calculate available liquidity vs. total liabilities
3. If `address(this).balance < totalPooledETH`, a bank-run is possible
4. Quickly withdraw spETH to drain remaining liquid ETH
5. Other users are locked out — their spETH is effectively illiquid

---

### V-08 — Reward Rate Change Loses Pending Rewards (**Medium**)

| Field | Value |
|-------|-------|
| **Contract** | `RewardController.sol` |
| **Function** | `notifyRewardAmount()` |
| **Category** | Stale state / unsettled rewards |
| **Impact** | Permanent loss of accumulated SPEC rewards for stakers |

**Description**: `notifyRewardAmount()` changes the reward rate and resets `lastUpdateTime` without first calling `_updatePool()`. Any rewards that accumulated between the last update and the rate change are never accounted for in `accRewardPerShare` — they're effectively lost forever. The SPEC tokens remain unminted, and no staker can ever claim them.

**Attack Vector**: This triggers on normal admin operations (not necessarily malicious). Every time the owner adjusts reward rates, pending rewards since the last pool interaction are permanently lost. Over many rate changes, cumulative reward loss can be substantial.

---

### V-09 — Expired Lock Retains Governance Voting Power (**Medium**)

| Field | Value |
|-------|-------|
| **Contract** | `VestedEscrow.sol` |
| **Function** | `votingPower()` |
| **Category** | Governance exploitation |
| **Impact** | Expired locks dilute active voters; governance manipulation without commitment |

**Description**: `votingPower()` does not check whether a lock has expired. It returns `amount * lockDuration / MAX_LOCK_DURATION` regardless of current time. Users who let their locks expire (without withdrawing) retain full voting power indefinitely. This dilutes the governance influence of users who actively commit tokens and enables governance manipulation without any ongoing commitment.

**Attack Vector**:
1. Lock large amount of SPEC for maximum duration
2. Let lock expire without calling `withdraw()`
3. Retain full voting power while tokens are technically withdrawable
4. Vote on proposals with "phantom" commitment
5. Withdraw tokens whenever convenient — no actual lockup risk

---

### V-10 — YieldVault `mint()` Bypasses Deposit Fee (**Medium**)

| Field | Value |
|-------|-------|
| **Contract** | `YieldVault.sol` |
| **Function** | `mint()` |
| **Category** | Fee evasion |
| **Impact** | Protocol revenue loss — 0.3% deposit fee completely bypassable |

**Description**: The vault has two entry points: `deposit(assets)` which charges a 0.3% deposit fee and `mint(shares)` which does NOT charge any fee. Both functions achieve the same result (user receives vault shares for spETH). Sophisticated users will always use `mint()` to avoid the fee, making the deposit fee effectively non-functional and causing permanent revenue loss for the protocol.

**Attack Vector**:
1. Instead of calling `deposit(1000 spETH)` (which charges 3 spETH fee)
2. Calculate equivalent shares: `shares = 1000 * totalShares / totalManagedAssets`
3. Call `mint(shares)` — pays exact asset amount, ZERO fee
4. Same position, 0.3% cheaper
5. Every savvy user bypasses the fee → protocol revenue approaches zero

---

## Vulnerability Summary

| ID | Severity | Contract | Vulnerability |
|----|----------|----------|---------------|
| V-01 | **Critical** | `LeveragedStaking.sol` | Cross-function reentrancy in `closePosition()` — ETH sent before state clear allows re-entering `borrow()` with ghost collateral, creating unrecoverable bad debt |
| V-02 | **Critical** | `BondingCurve.sol` | Sell-side uses spot price (no slippage) vs buy-side AMM formula — large sellers extract ~50% more ETH than fair value, draining reserves |
| V-03 | **High** | `WithdrawalQueue.sol` | Exchange rate read at processing time (not request time) — front-running `reportRewards()` captures unearned yield after 7-day delay |
| V-04 | **High** | `VestedEscrow.sol` | `merge()` doesn't update `originalAmount` — early exit penalty calculated only on initial lock amount, merged tokens escape penalty |
| V-05 | **High** | `YieldVault.sol` | No deposit cooldown — sandwich attack on `harvest()` steals compounded yield without staking during earn period |
| V-06 | **High** | `SpectraRouter.sol` | `stakeThenDeposit()` passes `msg.value` instead of `spETHReceived` to vault — strands tokens when exchange rate ≠ 1:1 |
| V-07 | **High** | `LiquidStaking.sol` | `withdraw()` uses `totalPooledETH` (includes strategy-deployed ETH) without checking liquid balance — bank-run drains available ETH |
| V-08 | **Medium** | `RewardController.sol` | `notifyRewardAmount()` overwrites rate without accruing pending rewards — accumulated SPEC permanently lost |
| V-09 | **Medium** | `VestedEscrow.sol` | `votingPower()` doesn't check lock expiry — expired locks retain full governance power indefinitely |
| V-10 | **Medium** | `YieldVault.sol` | `mint()` doesn't charge deposit fee — complete bypass of 0.3% fee via alternative entry point |

Expected SolGuard Results: 2 Critical, 5 High, 3 Medium

---

## Compilation

```bash
forge build
```

## License

MIT
