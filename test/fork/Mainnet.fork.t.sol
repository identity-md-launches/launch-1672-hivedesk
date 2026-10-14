// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BenchmarkTracker} from "../../src/BenchmarkTracker.sol";
import {DeploymentConfig} from "../../src/DeploymentConfig.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Runs only under `forge test --fork-url <mainnet rpc>`. Without a mainnet fork (chain id 1 and
/// live feed code) every test here is skipped, so the offline verifier run is unaffected.
contract MainnetForkTest is Test {
    BenchmarkTracker tracker;

    function setUp() public {
        if (block.chainid != DeploymentConfig.CHAIN_ID || DeploymentConfig.BTC_USD_FEED.code.length == 0) {
            vm.skip(true);
            return;
        }
        tracker = new BenchmarkTracker(DeploymentConfig.BTC_USD_FEED, DeploymentConfig.EQUITY_USD_FEED);
    }

    function test_feedsAreTheOnesDocumented() public view {
        AggregatorV3Interface btc = AggregatorV3Interface(DeploymentConfig.BTC_USD_FEED);
        AggregatorV3Interface spy = AggregatorV3Interface(DeploymentConfig.EQUITY_USD_FEED);
        assertEq(btc.description(), "BTC / USD");
        assertEq(btc.decimals(), 8);
        assertEq(spy.description(), "SPY-USD (24/5)");
        assertEq(spy.decimals(), 8);
    }

    function test_livePricesAreFreshAndPositive() public view {
        uint256 btc = tracker.latestBtcPrice();
        uint256 spy = tracker.latestEquityPrice();
        assertGt(btc, 1_000e8, "BTC below $1,000 is not a real answer");
        assertGt(spy, 100e8, "SPY below $100 is not a real answer");
    }

    function test_snapshotWorksAgainstLiveFeeds() public {
        vm.roll(block.number + 1);
        uint256 epoch = tracker.snapshot();
        assertEq(epoch, 0);
        BenchmarkTracker.Snapshot memory s = tracker.getSnapshot(0);
        assertEq(s.btcNav, 1e18);
        assertEq(s.equityNav, 1e18);
        assertEq(s.flipNav, 1e18);
        assertGt(s.btcPrice, 0);
        assertGt(s.equityPrice, 0);
    }
}
