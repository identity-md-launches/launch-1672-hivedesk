# HiveDesk — agent swarm trading desk, run in public

An onchain trading desk operated by a swarm of AI agents, trading a real ETH balance in public on
Ethereum mainnet. Three benchmarks are tracked alongside it: hold BTC, hold an equity index proxy, and a
deterministic coin flip. Every decision, trade and published NAV is an event anyone can verify.

Token: **HiveDesk (HVD)**, 18 decimals, 1,000,000,000 fixed supply.

## Contents

| Path | What it is |
|---|---|
| `src/LaunchToken.sol` | The HVD token. Contract name `LaunchToken` as the launch manifest requires. |
| `src/DeskVault.sol` | Holds the ETH trading balance; shares, deposits, withdrawals, strategy allocations. |
| `src/StrategyRegistry.sol` | Append-only log of proposed strategies. |
| `src/BenchmarkTracker.sol` | Defines and records the three benchmarks per epoch. |
| `src/PerformanceOracle.sol` | Panel-signed, write-once NAV publications per epoch. |
| `src/DeploymentConfig.sol` | Every fixed parameter, as compile-time constants. |
| `script/Deploy.s.sol` | Reviewable deployment order; `deploy()` is what the tests call. |
| `test/` | Unit, fuzz and mainnet-fork tests. |
| `site/` | Static IPFS site that reads the live contracts. |
| `lib/forge-std` | forge-std v1.9.6, vendored as plain files. |

## Build and test

```
forge build
forge test
forge fmt --check
forge test --fork-url <mainnet rpc>   # also runs test/fork, against the live Chainlink feeds
```

Compiler pinned to `solc = "0.8.26"`, `bytecode_hash = "none"`, optimizer on. The fuzz suite was run with
`FOUNDRY_FUZZ_SEED=0x46a109ffdb76ad5fcc28d2e9399e990aa419dd3e326df5e41a04f43dbd846e3c`. Tests read no
environment variables; the fork tests skip themselves unless the chain id is 1 and the feeds have code.

Latest local results: 76 tests, all passing (fork suite: 3 passing against mainnet).

## Design

### No owner, anywhere

No deployed contract has an owner, an `onlyOwner` function, a pause switch or an upgrade path. Every
parameter is either an immutable set in the constructor or a constant in `DeploymentConfig`. The "Owner"
of the launch (0x612a9bb008e16ef2d24f41dae9fc661831d93367) is the deployer of record only and holds no
power over any contract. The two operational roles the brief defines, the strategy wallet and the oracle
panel, are fixed at deployment and cannot be changed.

### LaunchToken (HVD)

Plain ERC-20. Mints 10^27 minor units to `msg.sender` once; no mint, burn, pause, fee, blocklist or
upgrade. The factory splits the supply: 10% to the swarm, 80% to the pool, 10% to the paying wallet. No
contract here is allocated any HVD at launch.

### DeskVault

- Denominated in ETH. `deposit()` mints shares at the current NAV; `withdraw(shares, receiver)` burns
  them and pays ETH. Anyone may deposit.
- `totalAssets = idle ETH + deployedCapital` where `deployedCapital` is capital out with the strategy
  wallet at cost. NAV per share is `navPerShare()`.
- Only the immutable `strategyWallet` may call `allocate(strategyId, amount)` and
  `returnCapital(strategyId)`. An allocation must reference a registry entry proposed by the strategy
  wallet itself, each id can be executed once, and capital out can never exceed
  `MAX_ALLOCATION_BPS` (80%) of total assets, so at least 20% stays idle for withdrawals.
- `returnCapital` is payable: the full proceeds are sent back and the difference to principal is the
  realised P&L (`TradeSettled`). A zero-value settlement writes the trade off as a total loss.
- Withdrawals are never gated by anyone. They fail only when the vault holds less idle ETH than the
  shares are worth (`InsufficientLiquidity`), which can happen while capital is out trading. There is no
  switch that can block them.
- First-depositor inflation is defeated with a virtual-share offset (10^3 shares, 1 wei) as in
  OpenZeppelin ERC-4626 v5. Rounding always favours the vault; dust stays with shareholders.
- Plain ETH sent to the vault is a donation to all shareholders. The strategy wallet is refused on
  `receive()` so it cannot return capital without settling.
- Checks-effects-interactions plus a reentrancy lock on every state-changing function.

### StrategyRegistry

`propose(bytes32 decisionHash)` appends `{decisionHash, timestamp, executor = msg.sender}` under the next
id (ids start at 1) and emits `StrategyProposed`. Anyone may propose, so every swarm agent logs its own
decisions; the vault only trades ids proposed by the strategy wallet. There is no other mutating
function: nothing deletes or rewrites.

### BenchmarkTracker

Epochs of `EPOCH_BLOCKS` (7200, about one day) from the deployment block.

- **Hold BTC**: Chainlink BTC/USD, indexed to the first snapshot.
- **Hold equity index proxy**: Chainlink SPY-USD (24/5), SPY tracking the S&P 500, indexed to the
  first snapshot.
- **Coin flip**: the low bit of the epoch's start blockhash. Heads holds BTC until the next snapshot,
  tails holds cash. Deterministic and reproducible by anyone while the blockhash is readable.

`snapshot()` is permissionless and records, once per epoch, both prices and the flip, from the block after
the epoch starts until `SNAPSHOT_WINDOW` (200) blocks later. Feeds must be fresh (`BTC_FEED_MAX_AGE` 2 h,
`EQUITY_FEED_MAX_AGE` 72 h to cover the equity feed's weekend gap) and positive. Everything else is a
view. "Read-only" here means no privileged write: the only state written is public chain data anyone can
recompute. If nobody snapshots an epoch within the window, that epoch is missing and the flip benchmark
holds cash across the gap. The first caller in a window fixes the exact block; that is a small liberty
inside a 200-block window, not a gate.

### PerformanceOracle

A fixed panel of three signers (`ORACLE_PANEL_SIZE`), two of whom (`ORACLE_THRESHOLD`) must sign the
same EIP-712 `Report(epoch, deskNav, btcNav, equityNav, flipNav, reportHash)`. Anyone may submit the
signed report with `publish`. An epoch can be published only after it has ended and only once: no admin,
no setter, no delete, so a published value can never be rewritten by anyone, let alone a single admin.
Signatures must come from distinct panel members in ascending address order; low-s and v ∈ {27, 28} are
enforced; the digest binds chain id and contract address. `reportHash` is meant to be the digest of the
full off-chain report (for example an IPFS CID) that the panel attests.

The oracle and the tracker share the epoch grid because they are deployed in the same transaction.

## Deployment parameters

All fixed values live in `src/DeploymentConfig.sol`:

| Constant | Value | Chosen because |
|---|---|---|
| `BTC_USD_FEED` | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` | Chainlink BTC/USD mainnet, verified live 2026-10-14 (`description()`, 8 decimals). |
| `EQUITY_USD_FEED` | `0x25efbA0d9b115D233cfA849F16BA743E8FFba2a1` | Chainlink SPY-USD (24/5) mainnet, verified live 2026-10-14. The brief leaves the index proxy open; SPY is the most liquid S&P 500 proxy with a live mainnet feed. |
| `BTC_FEED_MAX_AGE` | 2 hours | Two heartbeats of a 1 h feed. |
| `EQUITY_FEED_MAX_AGE` | 72 hours | 24 h heartbeat plus the weekend close. |
| `EPOCH_BLOCKS` | 7200 | About one day. Brief leaves the interval open. |
| `SNAPSHOT_WINDOW` | 200 blocks | Inside the 256-block blockhash range. |
| `MAX_ALLOCATION_BPS` | 8000 | Keeps 20% idle for withdrawals. Brief leaves it open. |
| `SHARE_OFFSET` | 1e3 | Inflation-attack mitigation. |
| `ORACLE_PANEL_SIZE` / `ORACLE_THRESHOLD` | 3 / 2 | Brief leaves the panel size open. |

### Launch inputs (constructor arguments)

Deployment order and arguments. Every contract takes static arguments and no constructor calls another
contract or needs code at an address; references are checked on first use.

| # | Contract | Constructor args |
|---|---|---|
| 0 | `LaunchToken` | none |
| 1 | `StrategyRegistry` | none |
| 2 | `DeskVault` | `strategyWallet` (requester-held), `registry` = `$contract:StrategyRegistry` |
| 3 | `BenchmarkTracker` | `btcFeed` = `BTC_USD_FEED`, `equityFeed` = `EQUITY_USD_FEED` |
| 4 | `PerformanceOracle` | `signer1`, `signer2`, `signer3` (requester-held, distinct, non-zero) |

Two inputs are values only the requester holds and the brief does not give. Because the brief forbids
owner roles and setters, they cannot be configured after launch and must be supplied as constructor
arguments to the manifest step:

- **Strategy wallet**: the swarm's execution wallet, the only account that can move vault funds to trade.
  Not the paying wallet; the brief says the paying wallet must retain no power.
- **Oracle panel signers (3)**: the swarm oracle panel's signing keys.

No placeholder, zero address or test key is baked in anywhere; the tests use locally generated addresses.
`script/Deploy.s.sol` reads these from `HIVEDESK_STRATEGY_WALLET` and `HIVEDESK_ORACLE_SIGNER_{1,2,3}`
only in `run()`; the launch itself is performed by IMD's factory from the built bytecode.

## What the brief asked that this does not do

- **Pair with ETH**: the launch policy pairs the pool with IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) at the network's 1.25% trading fee. The desk itself
  trades ETH; the pool pairing is the factory's.
- **Token contract name**: the brief calls it `HiveDeskToken`; the manifest requires `LaunchToken`.
  The token's `name()` is "HiveDesk" and `symbol()` "HVD" as asked.
- **Equity index proxy**: the brief does not name one; SPY/USD is the chosen proxy (above).
- **Start block**: fixed at the deployment block, the only block fixed before launch.

## Operational responsibilities

- **Strategy wallet** (the swarm): proposes each decision in `StrategyRegistry` before trading, calls
  `allocate` against that id, trades off-vault, and returns the full proceeds with `returnCapital`. It
  must never send plain ETH to the vault (refused) and must settle every open trade; an unsettled trade
  keeps capital counted at cost in NAV. It is trusted with up to 80% of total assets: this is the desk's
  core trust assumption and is stated to depositors.
- **Oracle panel**: at each epoch end, computes desk NAV per share (`navPerShare()`), the three benchmark
  NAVs (from `BenchmarkTracker` snapshots) and the report hash, signs the EIP-712 report, and anyone
  submits it. A publication is final.
- **Snapshotter** (anyone, typically a swarm agent): calls `BenchmarkTracker.snapshot()` in the 200-block
  window after each epoch starts. Missed windows are gaps.
- **Site maintainer**: fills `site/config.js` with the deployed addresses (or passes them as URL
  parameters) and pins `site/` to IPFS.

## Security notes and assumptions

- Depositors trust the strategy wallet with the allocated capital. The 80% cap and permissionless
  withdrawal of idle ETH are the only protections; a dishonest or compromised strategy wallet can lose
  what it holds. There is deliberately no admin that could stop it, by the brief's rules.
- NAV while a trade is open counts capital at cost. Depositors and withdrawers during an open trade
  transact at that NAV; the realised result is applied on settlement.
- Benchmark prices come from Chainlink with staleness and sign checks; the coin flip uses a blockhash,
  which a builder can influence, so it is a transparency device, not randomness anyone should pay for.
- The oracle's figures are attested by the panel, not computed on chain; readers can cross-check desk NAV
  against `navPerShare()` and benchmark NAVs against `BenchmarkTracker` events.
- Tests passing is not an audit. This holds other people's funds and needs an independent adversarial
  review before release.
- Tools run: `forge build`, `forge test` (unit, fuzz with the verifier seed, mainnet fork), `forge fmt`,
  forge's built-in lints (warnings only, reviewed). Slither and Mythril were not available here.

## Website (`site/`)

Static, no build step, pin the folder to IPFS. It reads the live contracts over a public RPC (editable in
the page) and shows: NAV of the desk vs the three benchmarks, a P&L chart with table view, the full
trade log with decision hashes, the strategy registry, benchmark snapshots, and a "verify onchain" panel
linking every number to its event, block and transaction. It never asks for a wallet.
