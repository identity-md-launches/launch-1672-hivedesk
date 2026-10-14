// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {DeskVault} from "../src/DeskVault.sol";
import {PerformanceOracle} from "../src/PerformanceOracle.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";

/// @notice Pins the four requester-held mainnet addresses the follow-up brief supplied and proves the
/// contracts, deployed with exactly those constructor arguments, grant power to them and to nobody else.
/// The panel's private keys are not available here, so the oracle tests show that signatures from any
/// other key are refused; a quorum of the real panel is exercised with local keys in PerformanceOracle.t.sol.
contract LaunchInputsTest is Test {
    // The values as written in the brief. Repeated here, not read from the config, so a change to the
    // constants without a matching change to this test fails loudly.
    address constant BRIEF_STRATEGY_WALLET = 0xAF5a05077Da3e3D130d66C1C73362306cc89d899;
    address constant BRIEF_SIGNER_1 = 0xC4F6e66C24fDc6Ae0f859c468dd177f8100b4959;
    address constant BRIEF_SIGNER_2 = 0xc9b5c6b29F66D526b76e68198F70d66342b0d84c;
    address constant BRIEF_SIGNER_3 = 0xFc5c95f0c55815fB7cC4793CC2aDF6D4452221FC;

    Deploy deployer;
    Deploy.Deployment d;

    address depositor = makeAddr("depositor");
    address outsider = makeAddr("outsider");

    function setUp() public {
        vm.roll(21_000_000);
        deployer = new Deploy();
        d = deployer.deploy(deployer.mainnetInputs());
        vm.deal(depositor, 100 ether);
    }

    // ------------------------------------------------------------------------------------------------
    // The configured values
    // ------------------------------------------------------------------------------------------------

    function test_configMatchesTheBrief() public pure {
        assertEq(DeploymentConfig.STRATEGY_WALLET, BRIEF_STRATEGY_WALLET);
        assertEq(DeploymentConfig.ORACLE_SIGNER_1, BRIEF_SIGNER_1);
        assertEq(DeploymentConfig.ORACLE_SIGNER_2, BRIEF_SIGNER_2);
        assertEq(DeploymentConfig.ORACLE_SIGNER_3, BRIEF_SIGNER_3);
    }

    function test_allFourAreNonZeroAndDistinct() public pure {
        address[4] memory all = [
            DeploymentConfig.STRATEGY_WALLET,
            DeploymentConfig.ORACLE_SIGNER_1,
            DeploymentConfig.ORACLE_SIGNER_2,
            DeploymentConfig.ORACLE_SIGNER_3
        ];
        for (uint256 i; i < all.length; ++i) {
            assertTrue(all[i] != address(0), "zero address");
            assertTrue(all[i] != address(0xdead), "dead address");
            for (uint256 j = i + 1; j < all.length; ++j) {
                assertTrue(all[i] != all[j], "duplicate address");
            }
        }
    }

    function test_mainnetInputsUseOnlyConfiguredConstants() public view {
        Deploy.Inputs memory i = deployer.mainnetInputs();
        assertEq(i.strategyWallet, DeploymentConfig.STRATEGY_WALLET);
        assertEq(i.signer1, DeploymentConfig.ORACLE_SIGNER_1);
        assertEq(i.signer2, DeploymentConfig.ORACLE_SIGNER_2);
        assertEq(i.signer3, DeploymentConfig.ORACLE_SIGNER_3);
        assertEq(i.btcFeed, DeploymentConfig.BTC_USD_FEED);
        assertEq(i.equityFeed, DeploymentConfig.EQUITY_USD_FEED);
    }

    // ------------------------------------------------------------------------------------------------
    // Deployment with the mainnet inputs
    // ------------------------------------------------------------------------------------------------

    function test_deploymentWiresTheBriefAddresses() public view {
        assertEq(d.vault.strategyWallet(), BRIEF_STRATEGY_WALLET);
        assertEq(d.oracle.signer1(), BRIEF_SIGNER_1);
        assertEq(d.oracle.signer2(), BRIEF_SIGNER_2);
        assertEq(d.oracle.signer3(), BRIEF_SIGNER_3);
        assertTrue(d.oracle.isPanelSigner(BRIEF_SIGNER_1));
        assertTrue(d.oracle.isPanelSigner(BRIEF_SIGNER_2));
        assertTrue(d.oracle.isPanelSigner(BRIEF_SIGNER_3));
    }

    function test_rolesDoNotLeakAcrossContracts() public view {
        // The strategy wallet is not on the oracle panel and no panel member is the strategy wallet.
        assertFalse(d.oracle.isPanelSigner(BRIEF_STRATEGY_WALLET));
        assertTrue(d.vault.strategyWallet() != BRIEF_SIGNER_1);
        assertTrue(d.vault.strategyWallet() != BRIEF_SIGNER_2);
        assertTrue(d.vault.strategyWallet() != BRIEF_SIGNER_3);
        // Neither the deployer of record nor the launch's owner holds any role.
        assertFalse(d.oracle.isPanelSigner(address(deployer)));
        assertTrue(d.vault.strategyWallet() != address(deployer));
        address launchOwner = 0x612a9bB008e16ef2D24f41DAe9Fc661831d93367;
        assertFalse(d.oracle.isPanelSigner(launchOwner));
        assertTrue(d.vault.strategyWallet() != launchOwner);
    }

    function test_constructorsNeedNoCodeAtTheBriefAddresses() public view {
        // The launch checks run on an empty chain; the addresses are EOAs there and on mainnet.
        assertEq(BRIEF_STRATEGY_WALLET.code.length, 0);
        assertEq(BRIEF_SIGNER_1.code.length, 0);
        assertEq(BRIEF_SIGNER_2.code.length, 0);
        assertEq(BRIEF_SIGNER_3.code.length, 0);
        assertGt(address(d.vault).code.length, 0);
        assertGt(address(d.oracle).code.length, 0);
    }

    // ------------------------------------------------------------------------------------------------
    // DeskVault: only the brief's strategy wallet can move funds
    // ------------------------------------------------------------------------------------------------

    function _fundAndPropose() internal returns (uint256 id) {
        vm.prank(depositor);
        d.vault.deposit{value: 10 ether}();
        vm.prank(BRIEF_STRATEGY_WALLET);
        id = d.registry.propose(keccak256("decision"));
    }

    function test_strategyWalletCanAllocateAndSettle() public {
        uint256 id = _fundAndPropose();

        vm.prank(BRIEF_STRATEGY_WALLET);
        d.vault.allocate(id, 4 ether);
        assertEq(BRIEF_STRATEGY_WALLET.balance, 4 ether);
        assertEq(d.vault.deployedCapital(), 4 ether);
        assertEq(d.vault.totalAssets(), 10 ether);

        vm.deal(BRIEF_STRATEGY_WALLET, 5 ether);
        vm.prank(BRIEF_STRATEGY_WALLET);
        d.vault.returnCapital{value: 5 ether}(id);
        assertEq(d.vault.deployedCapital(), 0);
        assertEq(d.vault.realizedPnl(), 1 ether);
        assertEq(d.vault.totalAssets(), 11 ether);
    }

    function test_strategyWalletCannotExceedTheCap() public {
        uint256 id = _fundAndPropose();
        vm.prank(BRIEF_STRATEGY_WALLET);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.AllocationCapExceeded.selector, 9 ether, 8 ether));
        d.vault.allocate(id, 9 ether);
    }

    function test_oracleSignersAndOutsidersCannotMoveVaultFunds() public {
        uint256 id = _fundAndPropose();
        address[5] memory callers = [BRIEF_SIGNER_1, BRIEF_SIGNER_2, BRIEF_SIGNER_3, outsider, address(deployer)];
        for (uint256 k; k < callers.length; ++k) {
            vm.prank(callers[k]);
            vm.expectRevert(abi.encodeWithSelector(DeskVault.NotStrategyWallet.selector, callers[k]));
            d.vault.allocate(id, 1 ether);

            vm.deal(callers[k], 1 ether);
            vm.prank(callers[k]);
            vm.expectRevert(abi.encodeWithSelector(DeskVault.NotStrategyWallet.selector, callers[k]));
            d.vault.returnCapital{value: 1 ether}(id);
        }
        assertEq(d.vault.deployedCapital(), 0);
        assertEq(address(d.vault).balance, 10 ether);
    }

    function test_vaultOnlyTradesStrategiesLoggedByTheStrategyWallet() public {
        vm.prank(depositor);
        d.vault.deposit{value: 10 ether}();
        // A decision logged by an oracle signer is a public record, not a tradable strategy.
        vm.prank(BRIEF_SIGNER_1);
        uint256 id = d.registry.propose(keccak256("not the desk"));
        vm.prank(BRIEF_STRATEGY_WALLET);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.StrategyNotOwnedByDesk.selector, id, BRIEF_SIGNER_1));
        d.vault.allocate(id, 1 ether);
    }

    function test_withdrawalsStayOpenWhileTheStrategyWalletTrades() public {
        uint256 id = _fundAndPropose();
        vm.prank(BRIEF_STRATEGY_WALLET);
        d.vault.allocate(id, 8 ether);

        uint256 shares = d.vault.sharesOf(depositor) / 10;
        uint256 before = depositor.balance;
        vm.prank(depositor);
        uint256 paid = d.vault.withdraw(shares, depositor);
        assertEq(depositor.balance - before, paid);
        assertGt(paid, 0);
    }

    function test_strategyWalletCannotBypassSettlementWithPlainEth() public {
        vm.deal(BRIEF_STRATEGY_WALLET, 1 ether);
        vm.prank(BRIEF_STRATEGY_WALLET);
        (bool ok, bytes memory ret) = address(d.vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(ret), DeskVault.UseReturnCapital.selector);
    }

    // ------------------------------------------------------------------------------------------------
    // PerformanceOracle: only the brief's panel can attest
    // ------------------------------------------------------------------------------------------------

    function _report() internal pure returns (PerformanceOracle.Report memory r) {
        r = PerformanceOracle.Report({
            epoch: 0,
            deskNav: 1e18,
            btcNav: 1e18,
            equityNav: 1e18,
            flipNav: 1e18,
            reportHash: keccak256("epoch 0 report")
        });
    }

    function digestOf(PerformanceOracle.Report calldata r) external view returns (bytes32) {
        return d.oracle.reportDigest(r);
    }

    function _sign(uint256 key, PerformanceOracle.Report memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, this.digestOf(r));
        return abi.encodePacked(rr, ss, v);
    }

    function test_signaturesFromKeysOutsideThePanelAreRefused() public {
        vm.roll(block.number + DeploymentConfig.EPOCH_BLOCKS);
        PerformanceOracle.Report memory r = _report();

        // Two well-formed signatures from keys that are not the panel's: a quorum in count, not in identity.
        (address k1Addr, uint256 k1) = makeAddrAndKey("impostor-1");
        (address k2Addr, uint256 k2) = makeAddrAndKey("impostor-2");
        bytes[] memory sigs = new bytes[](2);
        (uint256 lo, uint256 hi) = k1Addr < k2Addr ? (k1, k2) : (k2, k1);
        sigs[0] = _sign(lo, r);
        sigs[1] = _sign(hi, r);

        address firstRecovered = vm.addr(lo);
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.NotPanelSigner.selector, firstRecovered));
        d.oracle.publish(r, sigs);
        assertFalse(d.oracle.isPublished(0));
        assertEq(d.oracle.publishedCount(), 0);
    }

    function test_strategyWalletKeyCannotAttest() public {
        // Even the desk's own execution wallet is not a panel member: a signature from any key other than
        // the three panel keys recovers to a non-member and is refused before counting toward quorum.
        vm.roll(block.number + DeploymentConfig.EPOCH_BLOCKS);
        PerformanceOracle.Report memory r = _report();
        (, uint256 key) = makeAddrAndKey("some other operator key");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(key, r);
        sigs[1] = _sign(key, r);
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.NotPanelSigner.selector, vm.addr(key)));
        d.oracle.publish(r, sigs);
    }

    function test_panelSignersCannotBeChanged() public {
        bytes4[4] memory selectors = [
            bytes4(keccak256("setSigner(uint256,address)")),
            bytes4(keccak256("setSigners(address,address,address)")),
            bytes4(keccak256("setStrategyWallet(address)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 k; k < selectors.length; ++k) {
            (bool ok,) = address(d.oracle).call(abi.encodeWithSelector(selectors[k], outsider, outsider, outsider));
            assertFalse(ok, "oracle must expose no setter");
            (ok,) = address(d.vault).call(abi.encodeWithSelector(selectors[k], outsider, outsider, outsider));
            assertFalse(ok, "vault must expose no setter");
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Constructor rejection of the inputs the manifest step would otherwise refuse
    // ------------------------------------------------------------------------------------------------

    function test_oracleRejectsAPanelWithARepeatedBriefSigner() public {
        vm.expectRevert(PerformanceOracle.DuplicateSigner.selector);
        new PerformanceOracle(BRIEF_SIGNER_1, BRIEF_SIGNER_1, BRIEF_SIGNER_3);
        vm.expectRevert(PerformanceOracle.DuplicateSigner.selector);
        new PerformanceOracle(BRIEF_SIGNER_1, BRIEF_SIGNER_2, BRIEF_SIGNER_2);
        vm.expectRevert(PerformanceOracle.DuplicateSigner.selector);
        new PerformanceOracle(BRIEF_SIGNER_3, BRIEF_SIGNER_2, BRIEF_SIGNER_3);
    }

    function test_oracleRejectsAZeroSlotInTheBriefPanel() public {
        vm.expectRevert(PerformanceOracle.ZeroAddress.selector);
        new PerformanceOracle(address(0), BRIEF_SIGNER_2, BRIEF_SIGNER_3);
        vm.expectRevert(PerformanceOracle.ZeroAddress.selector);
        new PerformanceOracle(BRIEF_SIGNER_1, address(0), BRIEF_SIGNER_3);
        vm.expectRevert(PerformanceOracle.ZeroAddress.selector);
        new PerformanceOracle(BRIEF_SIGNER_1, BRIEF_SIGNER_2, address(0));
    }

    function test_vaultRejectsAZeroStrategyWallet() public {
        StrategyRegistry registry = new StrategyRegistry();
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(address(0), address(registry));
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(BRIEF_STRATEGY_WALLET, address(0));
    }

    function test_runRefusesAChainOtherThanMainnet() public {
        vm.chainId(11_155_111);
        vm.expectRevert(bytes("Deploy: mainnet only"));
        deployer.run();
    }
}
