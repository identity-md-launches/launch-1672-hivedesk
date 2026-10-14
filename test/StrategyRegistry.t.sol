// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {IStrategyRegistry} from "../src/interfaces/IStrategyRegistry.sol";

contract StrategyRegistryTest is Test {
    StrategyRegistry registry;
    address agentA = makeAddr("agentA");
    address agentB = makeAddr("agentB");

    function setUp() public {
        registry = new StrategyRegistry();
    }

    function test_proposeAppendsSequentialIds() public {
        vm.warp(1_700_000_000);
        bytes32 h1 = keccak256("decision 1");
        vm.prank(agentA);
        vm.expectEmit(true, true, true, true);
        emit StrategyRegistry.StrategyProposed(1, h1, agentA, 1_700_000_000);
        uint256 id1 = registry.propose(h1);

        vm.warp(1_700_000_060);
        vm.prank(agentB);
        uint256 id2 = registry.propose(keccak256("decision 2"));

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.count(), 2);

        IStrategyRegistry.Strategy memory s1 = registry.get(1);
        assertEq(s1.decisionHash, h1);
        assertEq(s1.timestamp, 1_700_000_000);
        assertEq(s1.executor, agentA);
        assertEq(registry.executorOf(2), agentB);
        assertEq(registry.get(2).timestamp, 1_700_000_060);
    }

    function test_proposeRejectsZeroHash() public {
        vm.expectRevert(StrategyRegistry.ZeroDecisionHash.selector);
        registry.propose(bytes32(0));
    }

    function test_getRevertsForUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.UnknownStrategy.selector, 0));
        registry.get(0);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.UnknownStrategy.selector, 1));
        registry.get(1);
        registry.propose(keccak256("x"));
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.UnknownStrategy.selector, 2));
        registry.executorOf(2);
    }

    function test_duplicateHashesAreSeparateEntries() public {
        bytes32 h = keccak256("same");
        registry.propose(h);
        registry.propose(h);
        assertEq(registry.count(), 2);
        assertEq(registry.get(1).decisionHash, h);
        assertEq(registry.get(2).decisionHash, h);
    }

    function test_noMutatingAdminSelectors() public {
        registry.propose(keccak256("keep"));
        string[6] memory sigs = [
            "remove(uint256)",
            "deleteStrategy(uint256)",
            "update(uint256,bytes32)",
            "owner()",
            "transferOwnership(address)",
            "clear()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(registry).call(abi.encodeWithSignature(sigs[i], uint256(1), bytes32(0)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(registry.count(), 1);
        assertEq(registry.get(1).decisionHash, keccak256("keep"));
    }

    function testFuzz_entriesAreImmutableOnceAppended(bytes32 h1, bytes32 h2, address a, address b) public {
        vm.assume(h1 != bytes32(0) && h2 != bytes32(0));
        vm.prank(a);
        registry.propose(h1);
        vm.prank(b);
        registry.propose(h2);
        IStrategyRegistry.Strategy memory s1 = registry.get(1);
        assertEq(s1.decisionHash, h1);
        assertEq(s1.executor, a);
        IStrategyRegistry.Strategy memory s2 = registry.get(2);
        assertEq(s2.decisionHash, h2);
        assertEq(s2.executor, b);
        assertEq(registry.count(), 2);
    }
}
