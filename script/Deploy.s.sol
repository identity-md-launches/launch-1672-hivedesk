// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {DeskVault} from "../src/DeskVault.sol";
import {BenchmarkTracker} from "../src/BenchmarkTracker.sol";
import {PerformanceOracle} from "../src/PerformanceOracle.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";

/// @notice Reviewable deployment logic. `deploy` takes every input as an argument and is what the tests
/// call; `run` only reads the requester-held inputs from the environment and forwards them. The launch
/// itself is performed by IMD's factory from the built bytecode in the order below, not by this script.
contract Deploy is Script {
    struct Inputs {
        address strategyWallet;
        address signer1;
        address signer2;
        address signer3;
        address btcFeed;
        address equityFeed;
    }

    struct Deployment {
        LaunchToken token;
        StrategyRegistry registry;
        DeskVault vault;
        BenchmarkTracker tracker;
        PerformanceOracle oracle;
    }

    /// @notice Deploys every contract in dependency order: token, registry, vault(registry), tracker, oracle.
    function deploy(Inputs memory inputs) public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.registry = new StrategyRegistry();
        d.vault = new DeskVault(inputs.strategyWallet, address(d.registry));
        d.tracker = new BenchmarkTracker(inputs.btcFeed, inputs.equityFeed);
        d.oracle = new PerformanceOracle(inputs.signer1, inputs.signer2, inputs.signer3);
    }

    /// @notice Mainnet defaults for the public feeds; the requester-held addresses come from the environment.
    function run() external returns (Deployment memory d) {
        Inputs memory inputs = Inputs({
            strategyWallet: vm.envAddress("HIVEDESK_STRATEGY_WALLET"),
            signer1: vm.envAddress("HIVEDESK_ORACLE_SIGNER_1"),
            signer2: vm.envAddress("HIVEDESK_ORACLE_SIGNER_2"),
            signer3: vm.envAddress("HIVEDESK_ORACLE_SIGNER_3"),
            btcFeed: DeploymentConfig.BTC_USD_FEED,
            equityFeed: DeploymentConfig.EQUITY_USD_FEED
        });
        vm.startBroadcast();
        d = deploy(inputs);
        vm.stopBroadcast();
    }
}
