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
/// call; `mainnetInputs` is the exact set of constructor arguments the mainnet launch uses, all from
/// `DeploymentConfig`; `run` forwards them under a broadcast and reads nothing from the environment. The
/// launch itself is performed by IMD's factory from the built bytecode in the order below, not by this script.
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

    /// @notice The constructor arguments of the Ethereum mainnet launch: the requester-held strategy wallet
    /// and oracle panel plus the public Chainlink feeds, every one a constant in `DeploymentConfig`.
    function mainnetInputs() public pure returns (Inputs memory) {
        return Inputs({
            strategyWallet: DeploymentConfig.STRATEGY_WALLET,
            signer1: DeploymentConfig.ORACLE_SIGNER_1,
            signer2: DeploymentConfig.ORACLE_SIGNER_2,
            signer3: DeploymentConfig.ORACLE_SIGNER_3,
            btcFeed: DeploymentConfig.BTC_USD_FEED,
            equityFeed: DeploymentConfig.EQUITY_USD_FEED
        });
    }

    /// @notice Deploys the mainnet configuration. Reads no environment variables; refuses any other chain.
    function run() external returns (Deployment memory d) {
        require(block.chainid == DeploymentConfig.CHAIN_ID, "Deploy: mainnet only");
        vm.startBroadcast();
        d = deploy(mainnetInputs());
        vm.stopBroadcast();
    }
}
