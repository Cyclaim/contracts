# Cyclaim — Uniswap v4 Swap-Rebate Hook

> **Every swap closes its own loop.**

![Solidity](https://img.shields.io/badge/Solidity-^0.8.26-363636?logo=solidity)
![EVM](https://img.shields.io/badge/EVM-Cancun-627EEA?logo=ethereum)
![Framework](https://img.shields.io/badge/Built%20with-Foundry-6C5CE7)
![Uniswap](https://img.shields.io/badge/Uniswap-v4%20Hook-FF007A)
![License](https://img.shields.io/badge/License-MIT-green)

Cyclaim is a [Uniswap v4](https://v4.uniswap.org/) hook that **backruns the price
divergence every swap creates — atomically, inside the same transaction — and
returns the realized profit to the people who created it**: the trader and the
liquidity providers.

Instead of letting external arbitrage bots capture the spread that a trade
leaves behind, the hook itself performs the closing cycle, measures the
**realized** profit, and splits it:

| Trade direction | Trader rebate | Liquidity providers |
|---|---|---|
| **BUY** (trader receives base) | **40%** | **60%** |
| **SELL** (trader receives quote) | **10%** | **90%** |

The LP side is further split **35% / 35% / 15% / 15%** across the two paired
pools and the two protocol pools (defaults; all parameters are
owner-configurable per pair).

**No captured profit → no payout.** Payments are computed exclusively from
completed, positive, realized cycles — estimates are never trusted, and a
failed capture can never revert the trader's swap.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Repository Layout](#repository-layout)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Security Model](#security-model)
- [License](#license)

---

## How It Works

Every swap pushes the pool it touched away from every other venue quoting the
same pair. Cyclaim captures that gap in the same transaction:

1. **Trigger** — the hook's `afterSwap` callback fires on every user swap in an
   attached pool. A transient-storage reentrancy guard (`tload`/`tstore`,
   Cancun) ensures the hook never backruns its own backrun.
2. **Isolation** — the capture runs through a `try/catch` boundary: any failure
   inside the capture loop emits a skip event and **never reverts the trader's
   swap**.
3. **Venue snapshot** — the engine collects a bounded set of venues: the pair's
   two paired v4 pools plus up to four owner-approved external AMM venues
   (anything exposing a v3-style lens — see `IExternalVenue`).
4. **Route planning** — `RouteChecker` enumerates bounded routes between the
   venues and estimates closed-form expected profit per cycle. Pure math only;
   nothing is executed on an estimate.
5. **Size caps** — the planned size is capped by the pair's absolute maximum,
   by a configurable fraction of the venues' active liquidity, and by the
   working capital the hook actually holds.
6. **Protected execution** — `SwapExecutor` runs the cycle as exact-input legs;
   outputs are pulled immediately (v4 `take`) and inputs paid per leg
   (v4 `settle`), leaving zero PoolManager deltas when the cycle ends.
7. **Realized accounting** — profit is measured by actual balance deltas, with
   base-neutrality enforced within a dust tolerance. Only a realized profit at
   or above the pair minimum triggers a payout.
8. **Payout** — the trader's share is escrowed in `PayoutLedger` (claimable
   permissionlessly by the trader); the LP share accrues to the four
   configured pools and is streamed in-range via Uniswap v4 `donate`.
9. **Loss guard** — a realized loss beyond the configured cap trips an
   automatic emergency pause of the whole system.

Additional entry points:

- `backrun(pairId)` — permissionless keeper trigger that runs a capture in its
  own unlock session; the keeper earns the trader-side share as a bounty.
- `distributePoolRewards(poolId)` — pushes a pool's accrued rewards into the
  pool via `donate`, flowing pro-rata to in-range liquidity.
- Working-capital management — anyone may fund the hook's inventory; the owner
  may withdraw only above a per-token floor.

## Architecture

| Component | File | Responsibility |
|---|---|---|
| **RebateHook** | [`src/hook/RebateHook.sol`](src/hook/RebateHook.sol) | The v4 hook: auto-pairing on pool init, the `afterSwap` capture loop, keeper entry points, working-capital admin |
| **PoolRegistry** | [`src/registry/PoolRegistry.sol`](src/registry/PoolRegistry.sol) | Single source of truth: approved pairs, paired pools, external venues, protocol pools, parameters, pause switches |
| **RouteChecker** | [`src/libraries/RouteChecker.sol`](src/libraries/RouteChecker.sol) | Bounded route enumeration and closed-form profit estimation (pure math) |
| **SwapExecutor** | [`src/libraries/SwapExecutor.sol`](src/libraries/SwapExecutor.sol) | Protected cycle execution — take/settle legs, zero PoolManager deltas |
| **PayoutLedger** | [`src/rewards/PayoutLedger.sol`](src/rewards/PayoutLedger.sol) | Captured-value escrow and accounting; trader rebates and LP accruals — can never pay more than it captured |
| **SwapRouter** | [`src/periphery/SwapRouter.sol`](src/periphery/SwapRouter.sol) | Minimal non-custodial router: swap with slippage protection, add/remove liquidity |
| **Create2Factory** | [`src/periphery/Create2Factory.sol`](src/periphery/Create2Factory.sol) | Deterministic deployments — mines the hook address to the exact v4 permission mask (`address & 0x3FFF == 0x1040`) |
| **ExternalAMMPool** | [`src/periphery/ExternalAMMPool.sol`](src/periphery/ExternalAMMPool.sol) | Generic constant-product external venue implementing the v3-style lens (testnet/demo fixture) |
| **IExternalVenue** | [`src/interfaces/IExternalVenue.sol`](src/interfaces/IExternalVenue.sol) | Minimal integration interface any external AMM can implement to join a pair's venue set |
| **WrappedNative / TestToken** | [`src/tokens/`](src/tokens) | WETH9-style wrapper and ERC-20 fixtures (testnet only) |

Data flow per swap:

```
trader ──swap──► SwapRouter ──► v4 PoolManager ──afterSwap──► RebateHook
                                                                   │
                                              RouteChecker (plan)   │
                                              SwapExecutor (execute)
                                                                   │
                                              PayoutLedger (escrow) │
                              trader rebate ◄──claim── LP: donate ◄┘
```

## Repository Layout

```
.
├── src/
│   ├── hook/RebateHook.sol          # the v4 hook: capture loop & admin
│   ├── registry/PoolRegistry.sol    # pairs, pools, venues, params, pauses
│   ├── libraries/RouteChecker.sol   # bounded route estimation (pure math)
│   ├── libraries/SwapExecutor.sol   # protected cycle execution
│   ├── rewards/PayoutLedger.sol     # rebate escrow & LP accruals
│   ├── periphery/SwapRouter.sol     # minimal swap / liquidity router
│   ├── periphery/Create2Factory.sol # deterministic deployment factory
│   ├── periphery/ExternalAMMPool.sol# demo external venue
│   ├── interfaces/IExternalVenue.sol# external-venue lens interface
│   └── tokens/                      # WrappedNative, TestToken fixtures
├── script/                          # 4-step deployment & demo scripts
├── test/                            # Foundry test suites
├── deployments/                     # address artifacts (generated, gitignored)
├── foundry.toml
├── remappings.txt
└── .env.example
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
  (`forge`, `cast`, `anvil`) — install with `foundryup`.
- A chain with **Cancun EVM support** (transient storage) if deploying; tests
  run fully in-process.

### Install & Build

```bash
git clone <your-repo-url> cyclaim-contracts
cd cyclaim-contracts

# Install the pinned dependencies (exact versions from foundry.lock)
forge install foundry-rs/forge-std@v1.17.0 --no-commit
forge install Uniswap/v4-core@v4.0.0 --no-commit
forge install Uniswap/v4-periphery@c6e4754dab11bd38c6f08ac51c3c868569e93d64 --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-commit

forge build     # via_ir build (required by PoolManager contract size)
```

## Testing

```bash
forge test -vvv         # full suite with traces
forge coverage          # coverage report
forge snapshot          # gas snapshot
```

The suites cover:

- **Economic parity** — trader/LP splits match configured bps exactly for buys
  and sells, including rounding-dust handling.
- **Ledger solvency** — `capturedTotal == rebatesOutstanding + poolOutstanding`
  holds across arbitrary claim/distribute orderings; claims never exceed
  captured value.
- **Guards & pauses** — loss guard trips, system/pair/distribution pauses,
  working-capital floor, base-neutrality reverts.
- **Route math** — closed-form cycle estimation against brute-force references.
- **Registry semantics** — pairing, attachment, venue caps, parameter bounds.

## Deployment

The system is **chain-agnostic** and deploys in four idempotent steps. All
scripts record addresses to `deployments/deployment.json` (gitignored —
regenerate per deployment; never commit live addresses or keys).

### 1. Configure the environment

```bash
cp .env.example .env    # then fill in your RPC endpoint and deployer key
source .env
```

### 2. Deploy the infrastructure (Step 0)

Uniswap v4 `PoolManager` + lens + demo tokens:

```bash
forge script script/DeployInfrastructure.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```

### 3. Deploy the protocol system (Step 1)

Registry → CREATE2 factory → ledger → **CREATE2-mined RebateHook** (the salt is
mined so the address carries exactly the required permission bits,
`address & 0x3FFF == 0x1040`) → wiring → router:

```bash
forge script script/DeploySystem.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```

### 4. Seed a demo pair (Step 2, optional fixture)

Registers the pair, initializes the two paired hook pools, seeds liquidity,
registers an external venue and funds the hook's working capital:

```bash
forge script script/SetupDemoPair.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```

### 5. Verify end-to-end (Step 3, optional)

Executes a live demo trade and asserts the same-transaction capture, the 40%
trader rebate, LP accrual, reward distribution and the claim flow:

```bash
forge script script/DemoTrade.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```

## Configuration

All economic parameters live in `PoolRegistry.PairParams` and are
owner-adjustable per pair after registration:

| Parameter | Default | Meaning |
|---|---|---|
| `traderShareBuyBps` | 4000 (40%) | Trader share of a captured profit on buys |
| `traderShareSellBps` | 1000 (10%) | Trader share on sells (keeper bounty basis) |
| `lpPool1Bps` / `lpPool2Bps` | 3500 / 3500 | LP share to each paired pool |
| `lpProtocol1Bps` / `lpProtocol2Bps` | 1500 / 1500 | LP share to each protocol pool |
| `minProfitQuote` | — | Minimum realized profit to pay out |
| `maxTradeSizeQuote` | — | Absolute per-cycle size cap (quote units) |
| `maxSizeBpsOfLiquidity` | — | Cycle size ≤ this bps of venue liquidity |
| `baseDustToleranceBps` | — | Allowed base-balance drift per cycle |
| `maxLossGuardQuote` | — | Realized loss beyond this trips the breaker |
| `maxRouteChecks` | ≤ 16 | Bounds per-capture estimation work |
| `maxCyclesPerSwap` | ≤ 4 | Bounds per-capture executions |

Hard system caps enforced in code: at most 4 external venues per pair, 16
route checks and 4 executed cycles per capture.

## Security Model

**Guarantees by construction**

- **Trader-swap safety** — the entire capture is revert-isolated; hook failures
  can never fail a user's swap.
- **Estimates are never paid** — payouts derive exclusively from realized
  balance deltas of completed cycles.
- **Full-reserve escrow** — profit is deposited into `PayoutLedger` *before*
  any credit is created; the solvency invariant
  `capturedTotal == rebatesOutstanding + poolOutstanding` holds at rest.
- **Reentrancy protection** — a transient-storage guard blocks recursive
  captures; `tload`/`tstore` auto-discard on revert.
- **Bounded execution** — hard caps on venues, route checks and cycles bound
  worst-case `afterSwap` gas; capture size never exceeds working capital held.
- **Loss breaker** — realized losses beyond the configured cap pause the system
  automatically; granular system / pair / distribution pause switches exist.
- **Deterministic hook address** — CREATE2 salt mining guarantees the exact v4
  permission mask; the mask is re-asserted on-chain at deployment.

**Considerations**

- The owner controls splits, pauses, venues and excess working capital;
  consider renouncing or timelocking ownership in production.
- `ExternalAMMPool` and `TestToken` are demo fixtures, not production AMMs.
- External venues must be vetted before approval — a malicious venue could
  feed false state to the estimator (execution is still slippage-protected and
  profit is verified after realization).

> ⚠️ **This code has not undergone a third-party security audit.** Review it
> thoroughly and test on a testnet before any mainnet use.

## License

Distributed under the [MIT License](LICENSE).

---

*Built with [Foundry](https://book.getfoundry.sh/) on
[Uniswap v4](https://v4.uniswap.org/).*
