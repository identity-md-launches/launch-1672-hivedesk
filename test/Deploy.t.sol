// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @notice Exercises the deploy function directly with explicit inputs; no environment is read.
contract DeployTest is Test {
    Deploy deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function _inputs() internal returns (Deploy.Inputs memory) {
        return Deploy.Inputs({
            strategyWallet: makeAddr("strategy"),
            signer1: makeAddr("s1"),
            signer2: makeAddr("s2"),
            signer3: makeAddr("s3"),
            btcFeed: DeploymentConfig.BTC_USD_FEED,
            equityFeed: DeploymentConfig.EQUITY_USD_FEED
        });
    }

    function test_deploysEverythingWired() public {
        vm.roll(123_456);
        Deploy.Inputs memory i = _inputs();
        Deploy.Deployment memory d = deployer.deploy(i);

        // Token minted to the deployer of record (the Deploy contract here, the factory at launch).
        assertEq(d.token.totalSupply(), 10 ** 27);
        assertEq(d.token.balanceOf(address(deployer)), 10 ** 27);

        assertEq(address(d.vault.registry()), address(d.registry));
        assertEq(d.vault.strategyWallet(), i.strategyWallet);
        assertEq(address(d.tracker.btcFeed()), DeploymentConfig.BTC_USD_FEED);
        assertEq(address(d.tracker.equityFeed()), DeploymentConfig.EQUITY_USD_FEED);
        assertEq(d.oracle.signer1(), i.signer1);
        assertEq(d.oracle.signer2(), i.signer2);
        assertEq(d.oracle.signer3(), i.signer3);

        // Tracker and oracle share the epoch grid because they deploy in the same block.
        assertEq(d.tracker.startBlock(), 123_456);
        assertEq(d.oracle.startBlock(), 123_456);
        assertEq(d.tracker.epochStartBlock(1), d.oracle.epochEndBlock(0));
    }

    function test_noContractExposesAnOwner() public {
        Deploy.Deployment memory d = deployer.deploy(_inputs());
        address[5] memory targets =
            [address(d.token), address(d.registry), address(d.vault), address(d.tracker), address(d.oracle)];
        for (uint256 k; k < targets.length; ++k) {
            (bool ok,) = targets[k].call(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "owner() must not exist");
            (ok,) = targets[k].call(abi.encodeWithSignature("paused()"));
            assertFalse(ok, "paused() must not exist");
        }
    }

    function test_runtimeSizesWithinLimit() public {
        Deploy.Deployment memory d = deployer.deploy(_inputs());
        assertLe(address(d.token).code.length, 24_576);
        assertLe(address(d.registry).code.length, 24_576);
        assertLe(address(d.vault).code.length, 24_576);
        assertLe(address(d.tracker).code.length, 24_576);
        assertLe(address(d.oracle).code.length, 24_576);
    }

    function test_constructorsDoNotNeedCodeAtReferencedAddresses() public {
        // On an empty chain none of the feeds or the registry exist as code; constructors must not care.
        Deploy.Inputs memory i = _inputs();
        assertEq(i.btcFeed.code.length, 0);
        Deploy.Deployment memory d = deployer.deploy(i);
        assertGt(address(d.tracker).code.length, 0);
        assertGt(address(d.vault).code.length, 0);
    }
}
