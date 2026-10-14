// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeploymentConfig} from "./DeploymentConfig.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title HiveDesk benchmark tracker
/// @notice Defines and records the three references the desk is measured against, all from a fixed start
/// block (the deployment block) in epochs of EPOCH_BLOCKS:
///   1. hold BTC             - Chainlink BTC/USD, indexed to the first snapshot;
///   2. hold an equity index - Chainlink SPY/USD (S&P 500 proxy), indexed to the first snapshot;
///   3. coin flip            - the low bit of the epoch's start blockhash: heads holds BTC until the next
///                             snapshot, tails holds cash.
/// There is no privileged write. `snapshot()` is permissionless and records only data every node already
/// agrees on (feed answers and a blockhash), inside a bounded window after each epoch starts, once per
/// epoch. Everything else is a view.
/// @dev Blockhash is readable for 256 blocks, so a flip for an epoch nobody snapshotted in time is lost;
/// the flip benchmark then holds cash across the gap. This is documented in the README.
contract BenchmarkTracker {
    struct Snapshot {
        uint64 blockNumber;
        bool heads;
        bool recorded;
        uint256 btcPrice;
        uint256 equityPrice;
        uint256 btcNav;
        uint256 equityNav;
        uint256 flipNav;
    }

    AggregatorV3Interface public immutable btcFeed;
    AggregatorV3Interface public immutable equityFeed;

    /// @notice First block of epoch 0.
    uint256 public immutable startBlock;

    /// @notice BTC and equity prices of the first snapshot; every NAV is indexed to them.
    uint256 public baseBtcPrice;
    uint256 public baseEquityPrice;

    /// @notice Epoch of the most recent snapshot, and whether any snapshot exists.
    uint256 public lastEpoch;
    bool public hasSnapshot;
    uint256 public snapshotCount;

    mapping(uint256 epoch => Snapshot) private _snapshots;

    event BenchmarkSnapshot(
        uint256 indexed epoch,
        uint256 blockNumber,
        uint256 btcPrice,
        uint256 equityPrice,
        bool heads,
        uint256 btcNav,
        uint256 equityNav,
        uint256 flipNav
    );

    error ZeroAddress();
    error EpochNotStarted(uint256 epoch);
    error SnapshotWindowClosed(uint256 epoch, uint256 lastBlock);
    error AlreadyRecorded(uint256 epoch);
    error BlockhashUnavailable(uint256 blockNumber);
    error BadFeedAnswer(address feed, int256 answer);
    error StaleFeed(address feed, uint256 updatedAt);
    error NotRecorded(uint256 epoch);

    /// @param btcFeed_ Chainlink BTC/USD aggregator. Not called here; read on first snapshot.
    /// @param equityFeed_ Chainlink equity-index aggregator. Not called here; read on first snapshot.
    constructor(address btcFeed_, address equityFeed_) {
        if (btcFeed_ == address(0) || equityFeed_ == address(0)) revert ZeroAddress();
        btcFeed = AggregatorV3Interface(btcFeed_);
        equityFeed = AggregatorV3Interface(equityFeed_);
        startBlock = block.number;
    }

    // ------------------------------------------------------------------------------------------------
    // Epoch arithmetic
    // ------------------------------------------------------------------------------------------------

    function epochLength() external pure returns (uint256) {
        return DeploymentConfig.EPOCH_BLOCKS;
    }

    function epochOf(uint256 blockNumber) public view returns (uint256) {
        if (blockNumber < startBlock) return 0;
        return (blockNumber - startBlock) / DeploymentConfig.EPOCH_BLOCKS;
    }

    function epochStartBlock(uint256 epoch) public view returns (uint256) {
        return startBlock + epoch * DeploymentConfig.EPOCH_BLOCKS;
    }

    function currentEpoch() public view returns (uint256) {
        return epochOf(block.number);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    function getSnapshot(uint256 epoch) external view returns (Snapshot memory s) {
        s = _snapshots[epoch];
        if (!s.recorded) revert NotRecorded(epoch);
    }

    function isRecorded(uint256 epoch) external view returns (bool) {
        return _snapshots[epoch].recorded;
    }

    /// @notice The coin flip for `epoch`, if its start blockhash is still readable.
    function coinFlip(uint256 epoch) external view returns (bool available, bool heads) {
        uint256 start = epochStartBlock(epoch);
        if (start >= block.number || block.number - start > 256) return (false, false);
        bytes32 h = blockhash(start);
        if (h == bytes32(0)) return (false, false);
        return (true, uint256(h) & 1 == 1);
    }

    /// @notice Fresh BTC/USD answer or revert.
    function latestBtcPrice() external view returns (uint256) {
        return _read(btcFeed, DeploymentConfig.BTC_FEED_MAX_AGE);
    }

    /// @notice Fresh equity-index answer or revert.
    function latestEquityPrice() external view returns (uint256) {
        return _read(equityFeed, DeploymentConfig.EQUITY_FEED_MAX_AGE);
    }

    /// @notice True when `snapshot()` would succeed for the current epoch as far as timing goes.
    function snapshotOpen() external view returns (bool) {
        uint256 epoch = currentEpoch();
        uint256 start = epochStartBlock(epoch);
        return
            block.number > start && block.number <= start + DeploymentConfig.SNAPSHOT_WINDOW
                && !_snapshots[epoch].recorded;
    }

    // ------------------------------------------------------------------------------------------------
    // Permissionless recording
    // ------------------------------------------------------------------------------------------------

    /// @notice Records the current epoch's benchmark snapshot. Anyone may call, once per epoch, between
    /// the block after the epoch starts and SNAPSHOT_WINDOW blocks later.
    function snapshot() external returns (uint256 epoch) {
        epoch = currentEpoch();
        uint256 start = epochStartBlock(epoch);
        if (block.number <= start) revert EpochNotStarted(epoch);
        uint256 lastBlock = start + DeploymentConfig.SNAPSHOT_WINDOW;
        if (block.number > lastBlock) revert SnapshotWindowClosed(epoch, lastBlock);
        if (_snapshots[epoch].recorded) revert AlreadyRecorded(epoch);

        bytes32 h = blockhash(start);
        if (h == bytes32(0)) revert BlockhashUnavailable(start);
        bool heads = uint256(h) & 1 == 1;

        uint256 btc = _read(btcFeed, DeploymentConfig.BTC_FEED_MAX_AGE);
        uint256 equity = _read(equityFeed, DeploymentConfig.EQUITY_FEED_MAX_AGE);

        uint256 flipNav;
        if (!hasSnapshot) {
            baseBtcPrice = btc;
            baseEquityPrice = equity;
            hasSnapshot = true;
            flipNav = DeploymentConfig.WAD;
        } else {
            Snapshot storage prev = _snapshots[lastEpoch];
            flipNav = prev.heads ? prev.flipNav * btc / prev.btcPrice : prev.flipNav;
        }
        uint256 btcNav = DeploymentConfig.WAD * btc / baseBtcPrice;
        uint256 equityNav = DeploymentConfig.WAD * equity / baseEquityPrice;

        _snapshots[epoch] = Snapshot({
            blockNumber: uint64(block.number),
            heads: heads,
            recorded: true,
            btcPrice: btc,
            equityPrice: equity,
            btcNav: btcNav,
            equityNav: equityNav,
            flipNav: flipNav
        });
        lastEpoch = epoch;
        snapshotCount += 1;

        emit BenchmarkSnapshot(epoch, block.number, btc, equity, heads, btcNav, equityNav, flipNav);
    }

    function _read(AggregatorV3Interface feed, uint256 maxAge) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer(address(feed), answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StaleFeed(address(feed), updatedAt);
        }
        return uint256(answer);
    }
}
