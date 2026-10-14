// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address deployer = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "HiveDesk");
        assertEq(token.symbol(), "HVD");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, 1, 0));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        token.transfer(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 60e18));
        assertEq(token.allowance(alice, bob), 60e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 50e18));
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.balanceOf(alice), 50e18);
        assertEq(token.allowance(alice, bob), 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 11e18, 10e18));
        token.transferFrom(alice, bob, 11e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_noMintOrAdminSelectors() public {
        string[8] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "setFee(uint256)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], alice, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
