// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HiveDesk deployment configuration
/// @notice Every fixed parameter of the desk lives here as a compile-time constant. Nothing in this file can
/// be changed after deployment because no contract has an owner or a setter. Values that only the requester
/// holds (the strategy wallet and the oracle panel signers) are not here: they are constructor arguments,
/// listed in the README under "Launch inputs".
/// @dev All functions of this library are internal constants, so the compiler inlines them and no link
/// placeholder is left in any bytecode.
library DeploymentConfig {
    /// @notice The launch chain. Mainnet only.
    uint256 internal constant CHAIN_ID = 1;

    /// @notice 1e18 fixed point used for every NAV figure.
    uint256 internal constant WAD = 1e18;

    /// @notice Basis points denominator.
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------------------------------------
    // Benchmarks
    // ------------------------------------------------------------------------------------------------

    /// @notice Chainlink BTC / USD on Ethereum mainnet (8 decimals, 1 hour heartbeat).
    /// Verified live on 2026-10-14: description() == "BTC / USD", decimals() == 8.
    address internal constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    /// @notice Chainlink SPY-USD (24/5) on Ethereum mainnet (8 decimals, 24 hour heartbeat), the equity
    /// index proxy. SPY tracks the S&P 500. Verified live on 2026-10-14: description() == "SPY-USD (24/5)".
    address internal constant EQUITY_USD_FEED = 0x25efbA0d9b115D233cfA849F16BA743E8FFba2a1;

    /// @notice Oldest BTC answer the tracker accepts (two heartbeats).
    uint256 internal constant BTC_FEED_MAX_AGE = 2 hours;

    /// @notice Oldest equity answer the tracker accepts. The feed is 24/5: it does not update from the
    /// Friday close to the Monday open, so the bound must cover a weekend plus one heartbeat.
    uint256 internal constant EQUITY_FEED_MAX_AGE = 72 hours;

    /// @notice Length of one benchmark / publication epoch in blocks (about one day at 12 s blocks).
    uint256 internal constant EPOCH_BLOCKS = 7200;

    /// @notice A benchmark snapshot for an epoch may be recorded from the block after the epoch starts
    /// until this many blocks later. It must stay below 256 so the epoch's start blockhash is readable.
    uint256 internal constant SNAPSHOT_WINDOW = 200;

    // ------------------------------------------------------------------------------------------------
    // Desk vault
    // ------------------------------------------------------------------------------------------------

    /// @notice Share of total assets the strategy wallet may hold out of the vault at any time. The rest
    /// stays idle so depositors can always withdraw something.
    uint256 internal constant MAX_ALLOCATION_BPS = 8000;

    /// @notice Virtual-share offset (10^3) that defeats the first-depositor inflation attack.
    uint256 internal constant SHARE_OFFSET = 1e3;

    // ------------------------------------------------------------------------------------------------
    // Performance oracle
    // ------------------------------------------------------------------------------------------------

    /// @notice Size of the swarm oracle panel.
    uint256 internal constant ORACLE_PANEL_SIZE = 3;

    /// @notice Signatures required to publish one epoch's figures.
    uint256 internal constant ORACLE_THRESHOLD = 2;
}
