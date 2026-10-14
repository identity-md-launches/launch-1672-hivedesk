// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BenchmarkTracker} from "../src/BenchmarkTracker.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract BenchmarkTrackerTest is Test {
    MockAggregator btc;
    MockAggregator spy;
    BenchmarkTracker tracker;

    uint256 constant EPOCH = 7200;
    uint256 constant WINDOW = 200;
    uint256 start;

    function setUp() public {
        vm.roll(20_000_000);
        vm.warp(1_800_000_000);
        btc = new MockAggregator(8, "BTC / USD", 100_000e8);
        spy = new MockAggregator(8, "SPY-USD (24/5)", 700e8);
        tracker = new BenchmarkTracker(address(btc), address(spy));
        start = block.number;
    }

    /// @dev Moves to `start + epoch*EPOCH + offset`, refreshing both feeds so they are not stale.
    function _goto(uint256 epoch, uint256 offset) internal {
        uint256 target = start + epoch * EPOCH + offset;
        vm.roll(target);
        vm.warp(1_800_000_000 + (target - start) * 12);
        btc.set(btc.answer(), block.timestamp);
        spy.set(spy.answer(), block.timestamp);
    }

    function test_constructorFixesStartBlockAndFeeds() public view {
        assertEq(tracker.startBlock(), start);
        assertEq(address(tracker.btcFeed()), address(btc));
        assertEq(address(tracker.equityFeed()), address(spy));
        assertEq(tracker.epochLength(), EPOCH);
        assertEq(tracker.currentEpoch(), 0);
        assertFalse(tracker.hasSnapshot());
    }

    function test_constructorDoesNotCallFeeds() public {
        BenchmarkTracker t = new BenchmarkTracker(address(0xAAAA), address(0xBBBB));
        assertEq(address(t.btcFeed()), address(0xAAAA));
    }

    function test_constructorRejectsZeroFeeds() public {
        vm.expectRevert(BenchmarkTracker.ZeroAddress.selector);
        new BenchmarkTracker(address(0), address(spy));
        vm.expectRevert(BenchmarkTracker.ZeroAddress.selector);
        new BenchmarkTracker(address(btc), address(0));
    }

    function test_epochArithmetic() public view {
        assertEq(tracker.epochOf(start), 0);
        assertEq(tracker.epochOf(start + EPOCH - 1), 0);
        assertEq(tracker.epochOf(start + EPOCH), 1);
        assertEq(tracker.epochOf(start + 10 * EPOCH + 5), 10);
        assertEq(tracker.epochOf(start - 1), 0);
        assertEq(tracker.epochStartBlock(3), start + 3 * EPOCH);
    }

    function test_snapshotRevertsInTheStartBlockItself() public {
        vm.expectRevert(abi.encodeWithSelector(BenchmarkTracker.EpochNotStarted.selector, 0));
        tracker.snapshot();
        assertFalse(tracker.snapshotOpen());
    }

    function test_firstSnapshotSetsBaseAndUnitNavs() public {
        _goto(0, 1);
        assertTrue(tracker.snapshotOpen());
        (bool available, bool heads) = tracker.coinFlip(0);
        assertTrue(available);

        vm.expectEmit(true, false, false, true);
        emit BenchmarkTracker.BenchmarkSnapshot(0, block.number, 100_000e8, 700e8, heads, 1e18, 1e18, 1e18);
        uint256 epoch = tracker.snapshot();
        assertEq(epoch, 0);

        BenchmarkTracker.Snapshot memory s = tracker.getSnapshot(0);
        assertTrue(s.recorded);
        assertEq(s.heads, heads);
        assertEq(s.btcPrice, 100_000e8);
        assertEq(s.equityPrice, 700e8);
        assertEq(s.btcNav, 1e18);
        assertEq(s.equityNav, 1e18);
        assertEq(s.flipNav, 1e18);
        assertEq(tracker.baseBtcPrice(), 100_000e8);
        assertEq(tracker.baseEquityPrice(), 700e8);
        assertEq(tracker.lastEpoch(), 0);
        assertEq(tracker.snapshotCount(), 1);
        assertTrue(tracker.isRecorded(0));
        assertFalse(tracker.snapshotOpen());
    }

    function test_snapshotOncePerEpoch() public {
        _goto(0, 1);
        tracker.snapshot();
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(BenchmarkTracker.AlreadyRecorded.selector, 0));
        tracker.snapshot();
    }

    function test_snapshotWindowCloses() public {
        _goto(0, WINDOW);
        tracker.snapshot(); // last allowed block
        _goto(1, WINDOW + 1);
        assertFalse(tracker.snapshotOpen());
        vm.expectRevert(
            abi.encodeWithSelector(BenchmarkTracker.SnapshotWindowClosed.selector, 1, start + EPOCH + WINDOW)
        );
        tracker.snapshot();
    }

    function test_coinFlipFollowsStartBlockhash() public {
        _goto(2, 5);
        bytes32 h = blockhash(start + 2 * EPOCH);
        assertTrue(h != bytes32(0));
        (bool available, bool heads) = tracker.coinFlip(2);
        assertTrue(available);
        assertEq(heads, uint256(h) & 1 == 1);

        // Too old or not yet mined: unavailable.
        (available,) = tracker.coinFlip(0);
        assertFalse(available);
        (available,) = tracker.coinFlip(3);
        assertFalse(available);
    }

    function test_navsIndexToFirstSnapshotAndFlipFollowsRule() public {
        _goto(0, 1);
        tracker.snapshot();
        bool heads0 = tracker.getSnapshot(0).heads;

        // BTC doubles, SPY up 10%.
        _goto(1, 1);
        btc.set(200_000e8, block.timestamp);
        spy.set(770e8, block.timestamp);
        tracker.snapshot();
        BenchmarkTracker.Snapshot memory s1 = tracker.getSnapshot(1);
        assertEq(s1.btcNav, 2e18);
        assertEq(s1.equityNav, 1.1e18);
        assertEq(s1.flipNav, heads0 ? 2e18 : 1e18);

        // BTC halves again; skip epoch 2 entirely (gap) and record epoch 3.
        _goto(3, 1);
        btc.set(100_000e8, block.timestamp);
        tracker.snapshot();
        BenchmarkTracker.Snapshot memory s3 = tracker.getSnapshot(3);
        assertEq(s3.btcNav, 1e18);
        assertEq(s3.equityNav, 1.1e18);
        uint256 expectedFlip = s1.heads ? s1.flipNav * 100_000e8 / 200_000e8 : s1.flipNav;
        assertEq(s3.flipNav, expectedFlip);
        assertEq(tracker.lastEpoch(), 3);
        assertFalse(tracker.isRecorded(2));
        vm.expectRevert(abi.encodeWithSelector(BenchmarkTracker.NotRecorded.selector, 2));
        tracker.getSnapshot(2);
    }

    function test_snapshotRejectsStaleOrBadFeeds() public {
        _goto(0, 1);
        btc.set(100_000e8, block.timestamp - DeploymentConfig.BTC_FEED_MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BenchmarkTracker.StaleFeed.selector,
                address(btc),
                block.timestamp - DeploymentConfig.BTC_FEED_MAX_AGE - 1
            )
        );
        tracker.snapshot();

        btc.set(100_000e8, block.timestamp);
        spy.set(700e8, block.timestamp - DeploymentConfig.EQUITY_FEED_MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BenchmarkTracker.StaleFeed.selector,
                address(spy),
                block.timestamp - DeploymentConfig.EQUITY_FEED_MAX_AGE - 1
            )
        );
        tracker.snapshot();

        spy.set(700e8, block.timestamp);
        btc.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(BenchmarkTracker.BadFeedAnswer.selector, address(btc), int256(0)));
        tracker.snapshot();

        btc.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(BenchmarkTracker.BadFeedAnswer.selector, address(btc), int256(-1)));
        tracker.latestBtcPrice();

        btc.set(100_000e8, block.timestamp);
        assertEq(tracker.latestBtcPrice(), 100_000e8);
        assertEq(tracker.latestEquityPrice(), 700e8);
    }

    function test_equityFeedToleratesWeekendGap() public {
        _goto(0, 1);
        spy.set(700e8, block.timestamp - 60 hours);
        tracker.snapshot();
        assertEq(tracker.getSnapshot(0).equityPrice, 700e8);
    }

    function test_noAdminSelectors() public {
        string[5] memory sigs = ["owner()", "setFeed(address)", "reset()", "setStartBlock(uint256)", "pause()"];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(tracker).call(abi.encodeWithSignature(sigs[i], uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    function testFuzz_btcNavIsPriceRatio(uint64 p0, uint64 p1) public {
        uint256 price0 = bound(uint256(p0), 1e8, 1_000_000e8);
        uint256 price1 = bound(uint256(p1), 1e8, 1_000_000e8);
        _goto(0, 1);
        btc.set(int256(price0), block.timestamp);
        tracker.snapshot();
        _goto(1, 1);
        btc.set(int256(price1), block.timestamp);
        tracker.snapshot();
        assertEq(tracker.getSnapshot(1).btcNav, 1e18 * price1 / price0);
    }
}
