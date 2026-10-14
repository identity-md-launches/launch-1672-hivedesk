// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskVault} from "../src/DeskVault.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";

contract Reenterer {
    DeskVault vault;
    uint256 public attempts;
    bool public reentryReverted;

    constructor(DeskVault vault_) {
        vault = vault_;
    }

    function depositAll() external payable {
        vault.deposit{value: msg.value}();
    }

    function withdrawAll() external {
        vault.withdraw(vault.sharesOf(address(this)), address(this));
    }

    receive() external payable {
        if (attempts == 0) {
            attempts = 1;
            uint256 shares = vault.sharesOf(address(this));
            // Try to withdraw again while the first withdrawal's ETH transfer is in flight.
            (bool ok,) =
                address(vault).call(abi.encodeWithSelector(DeskVault.withdraw.selector, shares + 1, address(this)));
            reentryReverted = !ok;
        }
    }
}

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract DeskVaultTest is Test {
    StrategyRegistry registry;
    DeskVault vault;

    address strategy = makeAddr("strategy");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address outsider = makeAddr("outsider");

    uint256 constant OFFSET = 1e3;

    function setUp() public {
        registry = new StrategyRegistry();
        vault = new DeskVault(strategy, address(registry));
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(strategy, 0);
    }

    function _propose(address who, string memory label) internal returns (uint256 id) {
        vm.prank(who);
        id = registry.propose(keccak256(bytes(label)));
    }

    // ------------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------------

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(address(0), address(registry));
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(strategy, address(0));
    }

    function test_constructorDoesNotCallOtherContracts() public {
        // The registry address has no code here; construction must still succeed.
        DeskVault v = new DeskVault(strategy, address(0x1234));
        assertEq(address(v.registry()), address(0x1234));
        assertEq(v.strategyWallet(), strategy);
    }

    function test_noOwnerOrPauseSelectors() public {
        string[6] memory sigs = [
            "owner()",
            "pause()",
            "unpause()",
            "setStrategyWallet(address)",
            "transferOwnership(address)",
            "sweep(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(sigs[i], alice));
            assertFalse(ok, sigs[i]);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // ------------------------------------------------------------------------------------------------

    function test_firstDepositMintsOffsetShares() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit DeskVault.Deposited(alice, 10 ether, 10 ether * OFFSET);
        uint256 shares = vault.deposit{value: 10 ether}();
        assertEq(shares, 10 ether * OFFSET);
        assertEq(vault.sharesOf(alice), shares);
        assertEq(vault.totalShares(), shares);
        assertEq(vault.totalAssets(), 10 ether);
        assertApproxEqRel(vault.navPerShare(), 1e18 / OFFSET, 1e12);
    }

    function test_depositRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(DeskVault.ZeroAmount.selector);
        vault.deposit{value: 0}();
    }

    function test_depositIsPermissionless() public {
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        vault.deposit{value: 1 ether}();
        assertGt(vault.sharesOf(outsider), 0);
    }

    function test_withdrawReturnsProRataAndEmits() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 10 ether}();
        uint256 before = bob.balance;

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit DeskVault.Withdrawn(alice, bob, shares / 2, 0);
        uint256 assets = vault.withdraw(shares / 2, bob);

        assertApproxEqAbs(assets, 5 ether, 1e6);
        assertEq(bob.balance - before, assets);
        assertEq(vault.sharesOf(alice), shares - shares / 2);
        assertEq(vault.totalShares(), shares - shares / 2);
    }

    function test_withdrawRejectsBadInputs() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 1 ether}();

        vm.startPrank(alice);
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        vault.withdraw(shares, address(0));
        vm.expectRevert(DeskVault.ZeroShares.selector);
        vault.withdraw(0, alice);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.InsufficientShares.selector, shares + 1, shares));
        vault.withdraw(shares + 1, alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.InsufficientShares.selector, 1, 0));
        vault.withdraw(1, bob);
    }

    function test_withdrawRevertsWhenReceiverRejectsEth() public {
        RejectsEth r = new RejectsEth();
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(DeskVault.EthTransferFailed.selector);
        vault.withdraw(shares, address(r));
        // Nothing changed.
        assertEq(vault.sharesOf(alice), shares);
    }

    function test_withdrawIsNotGatedWhileCapitalIsDeployed() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "t1");
        vm.prank(strategy);
        vault.allocate(id, 80 ether);
        assertEq(address(vault).balance, 20 ether);

        // Alice can still withdraw up to the idle balance while the trade is open.
        uint256 quarter = shares / 5; // worth ~20 ETH of a 100 ETH NAV
        uint256 owed = vault.convertToAssets(quarter);
        assertLe(owed, 20 ether);
        vm.prank(alice);
        uint256 got = vault.withdraw(quarter, alice);
        assertEq(got, owed);

        // Asking for more than the idle balance fails with a clear reason, not a gate.
        uint256 rest = vault.sharesOf(alice);
        uint256 restOwed = vault.convertToAssets(rest);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DeskVault.InsufficientLiquidity.selector, restOwed, address(vault).balance)
        );
        vault.withdraw(rest, alice);
    }

    function test_reentrantWithdrawIsBlocked() public {
        Reenterer r = new Reenterer(vault);
        vm.deal(address(this), 5 ether);
        r.depositAll{value: 5 ether}();
        assertEq(address(r).balance, 0);
        vm.prank(bob);
        vault.deposit{value: 5 ether}();

        r.withdrawAll();
        assertEq(r.attempts(), 1);
        assertTrue(r.reentryReverted(), "re-entrant withdraw should revert");
        assertApproxEqAbs(address(r).balance, 5 ether, 1e6);
        assertApproxEqAbs(address(vault).balance, 5 ether, 1e6);
    }

    function test_inflationAttackIsUneconomic() public {
        // Attacker deposits 1 wei then donates 10 ETH to skew the share price.
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 20 ether);
        vm.prank(attacker);
        vault.deposit{value: 1}();
        vm.prank(attacker);
        (bool ok,) = address(vault).call{value: 10 ether}("");
        assertTrue(ok);

        // Victim deposits 5 ETH and must still receive shares worth close to 5 ETH.
        vm.prank(alice);
        uint256 victimShares = vault.deposit{value: 5 ether}();
        assertGt(victimShares, 0);
        uint256 victimValue = vault.convertToAssets(victimShares);
        assertGe(victimValue, 5 ether - 0.01 ether);

        // The attacker cannot get back more than they put in.
        uint256 attackerValue = vault.convertToAssets(vault.sharesOf(attacker));
        assertLe(attackerValue, 10 ether + 1);
    }

    function test_donationAccruesToShareholders() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 10 ether}();
        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit DeskVault.Donated(bob, 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertApproxEqRel(vault.convertToAssets(shares), 11 ether, 1e12);
    }

    function test_strategyCannotDonateInsteadOfSettling() public {
        vm.deal(strategy, 1 ether);
        vm.prank(strategy);
        (bool ok, bytes memory data) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(data), DeskVault.UseReturnCapital.selector);
    }

    // ------------------------------------------------------------------------------------------------
    // Allocation and settlement
    // ------------------------------------------------------------------------------------------------

    function test_onlyStrategyWalletCanAllocateOrSettle() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();
        uint256 id = _propose(strategy, "t");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.NotStrategyWallet.selector, alice));
        vault.allocate(id, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.NotStrategyWallet.selector, alice));
        vault.returnCapital(id);
    }

    function test_allocateRequiresStrategyLoggedByDesk() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();
        uint256 foreign = _propose(outsider, "someone else's idea");

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.StrategyNotOwnedByDesk.selector, foreign, outsider));
        vault.allocate(foreign, 1 ether);

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.UnknownStrategy.selector, 99));
        vault.allocate(99, 1 ether);
    }

    function test_allocateEnforcesCapAndIdleBalance() public {
        vm.prank(alice);
        vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "t");

        assertEq(vault.allocationHeadroom(), 80 ether);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.AllocationCapExceeded.selector, 80 ether + 1, 80 ether));
        vault.allocate(id, 80 ether + 1);

        vm.prank(strategy);
        vm.expectRevert(DeskVault.ZeroAmount.selector);
        vault.allocate(id, 0);

        vm.prank(strategy);
        vault.allocate(id, 80 ether);
        assertEq(strategy.balance, 80 ether);
        assertEq(vault.deployedCapital(), 80 ether);
        assertEq(vault.outstanding(id), 80 ether);
        assertTrue(vault.executed(id));
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.allocationHeadroom(), 0);

        uint256 id2 = _propose(strategy, "t2");
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.AllocationCapExceeded.selector, 1, 0));
        vault.allocate(id2, 1);
    }

    function test_allocateCapCountsCapitalAlreadyOut() public {
        vm.prank(alice);
        vault.deposit{value: 100 ether}();
        uint256 id1 = _propose(strategy, "a");
        uint256 id2 = _propose(strategy, "b");
        vm.startPrank(strategy);
        vault.allocate(id1, 50 ether);
        assertEq(vault.allocationHeadroom(), 30 ether);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.AllocationCapExceeded.selector, 31 ether, 30 ether));
        vault.allocate(id2, 31 ether);
        vault.allocate(id2, 30 ether);
        vm.stopPrank();
        assertEq(vault.deployedCapital(), 80 ether);
    }

    function test_strategyIdCanOnlyBeExecutedOnce() public {
        vm.prank(alice);
        vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "once");
        vm.startPrank(strategy);
        vault.allocate(id, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.StrategyAlreadyExecuted.selector, id));
        vault.allocate(id, 1 ether);
        vault.returnCapital{value: 1 ether}(id);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.StrategyAlreadyExecuted.selector, id));
        vault.allocate(id, 1 ether);
        vm.stopPrank();
    }

    function test_profitableTradeRaisesNav() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "win");
        vm.prank(strategy);
        vm.expectEmit(true, true, false, true);
        emit DeskVault.Allocated(id, keccak256("win"), 50 ether);
        vault.allocate(id, 50 ether);

        vm.deal(strategy, 60 ether);
        vm.prank(strategy);
        vm.expectEmit(true, false, false, true);
        emit DeskVault.TradeSettled(id, 50 ether, 60 ether, 10 ether);
        vault.returnCapital{value: 60 ether}(id);

        assertEq(vault.deployedCapital(), 0);
        assertEq(vault.outstanding(id), 0);
        assertEq(vault.realizedPnl(), 10 ether);
        assertEq(vault.totalAssets(), 110 ether);
        assertApproxEqRel(vault.convertToAssets(shares), 110 ether, 1e12);
    }

    function test_losingTradeLowersNavAndCanBeWrittenOff() public {
        vm.prank(alice);
        uint256 shares = vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "lose");
        vm.prank(strategy);
        vault.allocate(id, 40 ether);

        // Strategy burns the whole position; settles a total loss with zero value.
        vm.deal(strategy, 0);
        vm.prank(strategy);
        vm.expectEmit(true, false, false, true);
        emit DeskVault.TradeSettled(id, 40 ether, 0, -40 ether);
        vault.returnCapital(id);

        assertEq(vault.deployedCapital(), 0);
        assertEq(vault.realizedPnl(), -40 ether);
        assertEq(vault.totalAssets(), 60 ether);
        assertApproxEqRel(vault.convertToAssets(shares), 60 ether, 1e12);

        vm.prank(alice);
        uint256 got = vault.withdraw(shares, alice);
        assertApproxEqAbs(got, 60 ether, 1e6);
    }

    function test_returnCapitalRejectsUnknownOrSettledIds() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();
        uint256 id = _propose(strategy, "x");
        vm.startPrank(strategy);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.NothingToSettle.selector, id));
        vault.returnCapital(id);
        vault.allocate(id, 1 ether);
        vault.returnCapital{value: 1 ether}(id);
        vm.deal(strategy, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.NothingToSettle.selector, id));
        vault.returnCapital{value: 1 ether}(id);
        vm.stopPrank();
    }

    function test_depositPricedAtNavDuringOpenTrade() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit{value: 100 ether}();
        uint256 id = _propose(strategy, "open");
        vm.prank(strategy);
        vault.allocate(id, 80 ether);

        // NAV still 100 ETH, so Bob's 100 ETH buys the same number of shares as Alice's.
        vm.prank(bob);
        uint256 bobShares = vault.deposit{value: 100 ether}();
        assertApproxEqRel(bobShares, aliceShares, 1e12);
    }

    // ------------------------------------------------------------------------------------------------
    // Fuzz: conservation
    // ------------------------------------------------------------------------------------------------

    function testFuzz_withdrawalsNeverExceedDeposits(uint96 a, uint96 b, uint96 fractionBps) public {
        uint256 da = bound(uint256(a), 1e9, 500 ether);
        uint256 db = bound(uint256(b), 1e9, 500 ether);
        uint256 bps = bound(uint256(fractionBps), 1, 10_000);

        vm.prank(alice);
        uint256 sa = vault.deposit{value: da}();
        vm.prank(bob);
        uint256 sb = vault.deposit{value: db}();

        uint256 part = sa * bps / 10_000;
        if (part > 0) {
            vm.prank(alice);
            vault.withdraw(part, alice);
        }
        vm.prank(bob);
        vault.withdraw(sb, bob);
        if (sa - part > 0) {
            vm.prank(alice);
            vault.withdraw(sa - part, alice);
        }

        // Nobody got out more than they put in, and the vault never went negative.
        assertLe(alice.balance, 1_000 ether);
        assertLe(bob.balance, 1_000 ether);
        assertEq(vault.totalShares(), 0);
        // Rounding dust stays in the vault and is tiny.
        assertLe(address(vault).balance, 4);
    }

    function testFuzz_navTracksSettledPnl(uint96 depositWei, uint96 allocWei, uint96 returnWei) public {
        uint256 dep = bound(uint256(depositWei), 1 ether, 900 ether);
        uint256 alloc = bound(uint256(allocWei), 1, dep * 8 / 10);
        uint256 ret = bound(uint256(returnWei), 0, 2 * alloc);

        vm.prank(alice);
        vault.deposit{value: dep}();
        uint256 id = _propose(strategy, "f");
        vm.prank(strategy);
        vault.allocate(id, alloc);
        assertEq(vault.totalAssets(), dep);

        vm.deal(strategy, ret);
        vm.prank(strategy);
        vault.returnCapital{value: ret}(id);

        assertEq(vault.totalAssets(), dep - alloc + ret);
        assertEq(vault.realizedPnl(), int256(ret) - int256(alloc));
        assertEq(vault.deployedCapital(), 0);
    }
}
