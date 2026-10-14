// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PerformanceOracle} from "../src/PerformanceOracle.sol";

contract PerformanceOracleTest is Test {
    PerformanceOracle oracle;

    uint256 constant EPOCH = 7200;
    uint256 start;

    uint256 keyA = 0xA11CE;
    uint256 keyB = 0xB0B;
    uint256 keyC = 0xC0C0A;
    uint256 keyX = 0xBAD;
    address a;
    address b;
    address c;

    function setUp() public {
        vm.roll(20_000_000);
        a = vm.addr(keyA);
        b = vm.addr(keyB);
        c = vm.addr(keyC);
        oracle = new PerformanceOracle(a, b, c);
        start = block.number;
    }

    function _report(uint256 epoch) internal pure returns (PerformanceOracle.Report memory r) {
        r = PerformanceOracle.Report({
            epoch: epoch,
            deskNav: 1.05e18,
            btcNav: 1.2e18,
            equityNav: 1.01e18,
            flipNav: 0.98e18,
            reportHash: keccak256("ipfs report")
        });
    }

    function _sign(uint256 key, PerformanceOracle.Report memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, _digest(r));
        return abi.encodePacked(rr, ss, v);
    }

    function _digest(PerformanceOracle.Report memory r) internal view returns (bytes32) {
        return this.digestOf(r);
    }

    /// @dev Round-trips through an external call so the calldata-typed view can be used from memory.
    function digestOf(PerformanceOracle.Report calldata r) external view returns (bytes32) {
        return oracle.reportDigest(r);
    }

    /// @dev Two signatures ordered by ascending signer address.
    function _sorted(uint256 k1, uint256 k2, PerformanceOracle.Report memory r)
        internal
        view
        returns (bytes[] memory sigs)
    {
        sigs = new bytes[](2);
        if (vm.addr(k1) < vm.addr(k2)) {
            sigs[0] = _sign(k1, r);
            sigs[1] = _sign(k2, r);
        } else {
            sigs[0] = _sign(k2, r);
            sigs[1] = _sign(k1, r);
        }
    }

    function test_constructorValidation() public {
        vm.expectRevert(PerformanceOracle.ZeroAddress.selector);
        new PerformanceOracle(address(0), b, c);
        vm.expectRevert(PerformanceOracle.DuplicateSigner.selector);
        new PerformanceOracle(a, a, c);
        vm.expectRevert(PerformanceOracle.DuplicateSigner.selector);
        new PerformanceOracle(a, b, b);
        assertEq(oracle.threshold(), 2);
        assertEq(oracle.panelSize(), 3);
        assertTrue(oracle.isPanelSigner(a) && oracle.isPanelSigner(b) && oracle.isPanelSigner(c));
        assertFalse(oracle.isPanelSigner(vm.addr(keyX)));
        assertEq(oracle.startBlock(), start);
        assertEq(oracle.epochEndBlock(0), start + EPOCH);
    }

    function test_digestBindsChainAndContract() public {
        PerformanceOracle.Report memory r = _report(0);
        bytes32 d1 = _digest(r);
        vm.chainId(1);
        bytes32 d2 = _digest(r);
        assertTrue(d1 != d2, "digest must depend on chain id");
        PerformanceOracle other = new PerformanceOracle(a, b, c);
        bytes32 d3 = other.reportDigest(r);
        assertTrue(d2 != d3, "digest must depend on contract address");
    }

    function test_publishWithQuorumAndEvent() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = _sorted(keyA, keyB, r);

        vm.expectEmit(true, false, false, true);
        emit PerformanceOracle.Published(0, 1.05e18, 1.2e18, 1.01e18, 0.98e18, keccak256("ipfs report"), address(this));
        oracle.publish(r, sigs);

        assertTrue(oracle.isPublished(0));
        assertEq(oracle.publishedCount(), 1);
        PerformanceOracle.Publication memory p = oracle.getPublication(0);
        assertEq(p.deskNav, 1.05e18);
        assertEq(p.btcNav, 1.2e18);
        assertEq(p.equityNav, 1.01e18);
        assertEq(p.flipNav, 0.98e18);
        assertEq(p.reportHash, keccak256("ipfs report"));
        assertEq(p.blockNumber, block.number);
    }

    function test_anyoneCanSubmitWithValidSignatures() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = _sorted(keyB, keyC, r);
        vm.prank(makeAddr("relayer"));
        oracle.publish(r, sigs);
        assertTrue(oracle.isPublished(0));
    }

    function test_threeSignaturesAccepted() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        // Order the three by address.
        uint256[3] memory keys = [keyA, keyB, keyC];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keys[i], r);
        }
        oracle.publish(r, sigs);
        assertTrue(oracle.isPublished(0));
    }

    function test_cannotPublishBeforeEpochEnds() public {
        vm.roll(start + EPOCH - 1);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = _sorted(keyA, keyB, r);
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.EpochNotEnded.selector, 0));
        oracle.publish(r, sigs);
    }

    function test_publishedEpochCannotBeRewritten() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        oracle.publish(r, _sorted(keyA, keyB, r));

        PerformanceOracle.Report memory r2 = _report(0);
        r2.deskNav = 9e18;
        bytes[] memory all = new bytes[](3);
        // Even the full panel cannot replace a published epoch.
        uint256[3] memory keys = [keyA, keyB, keyC];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        for (uint256 i; i < 3; ++i) {
            all[i] = _sign(keys[i], r2);
        }
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.AlreadyPublished.selector, 0));
        oracle.publish(r2, all);
        assertEq(oracle.getPublication(0).deskNav, 1.05e18);
    }

    function test_singleSignatureIsRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keyA, r);
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.NotEnoughSignatures.selector, 1, 2));
        oracle.publish(r, sigs);
    }

    function test_duplicateSignerIsRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keyA, r);
        sigs[1] = _sign(keyA, r);
        vm.expectRevert(PerformanceOracle.SignersNotAscending.selector);
        oracle.publish(r, sigs);
    }

    function test_unorderedSignersAreRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sorted = _sorted(keyA, keyB, r);
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = sorted[1];
        reversed[1] = sorted[0];
        vm.expectRevert(PerformanceOracle.SignersNotAscending.selector);
        oracle.publish(r, reversed);
    }

    function test_outsiderSignatureIsRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keyA, r);
        sigs[1] = _sign(keyX, r);
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.NotPanelSigner.selector, vm.addr(keyX)));
        oracle.publish(r, sigs);
    }

    function test_signatureOverDifferentReportIsRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        PerformanceOracle.Report memory tampered = _report(0);
        tampered.deskNav = 2e18;
        bytes[] memory sigs = _sorted(keyA, keyB, r);
        // Signed over r, submitted with tampered figures: recovers to a random non-panel address.
        vm.expectRevert();
        oracle.publish(tampered, sigs);
        assertFalse(oracle.isPublished(0));
    }

    function test_replayAcrossEpochsIsRejected() public {
        vm.roll(start + 2 * EPOCH);
        PerformanceOracle.Report memory r0 = _report(0);
        bytes[] memory sigs = _sorted(keyA, keyB, r0);
        oracle.publish(r0, sigs);
        PerformanceOracle.Report memory r1 = _report(1);
        vm.expectRevert();
        oracle.publish(r1, sigs);
        assertFalse(oracle.isPublished(1));
    }

    function test_malformedSignaturesAreRejected() public {
        vm.roll(start + EPOCH);
        PerformanceOracle.Report memory r = _report(0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = hex"00";
        sigs[1] = _sign(keyB, r);
        vm.expectRevert(PerformanceOracle.InvalidSignatureLength.selector);
        oracle.publish(r, sigs);

        // High-s variant of a valid signature.
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(keyA, _digest(r));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(ss));
        uint8 flippedV = v == 27 ? 28 : 27;
        sigs[0] = abi.encodePacked(rr, highS, flippedV);
        vm.expectRevert(PerformanceOracle.InvalidSignature.selector);
        oracle.publish(r, sigs);

        // Bad v.
        sigs[0] = abi.encodePacked(rr, ss, uint8(5));
        vm.expectRevert(PerformanceOracle.InvalidSignature.selector);
        oracle.publish(r, sigs);
    }

    function test_getPublicationRevertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(PerformanceOracle.NotPublished.selector, 7));
        oracle.getPublication(7);
    }

    function test_noAdminSelectors() public {
        string[6] memory sigs = [
            "owner()",
            "setSigner(uint256,address)",
            "unpublish(uint256)",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(oracle).call(abi.encodeWithSignature(sigs[i], uint256(1), a));
            assertFalse(ok, sigs[i]);
        }
    }

    function testFuzz_publishStoresExactFigures(
        uint256 epoch,
        uint256 desk,
        uint256 btc,
        uint256 eq,
        uint256 flip,
        bytes32 h
    ) public {
        epoch = bound(epoch, 0, 1_000_000);
        vm.roll(start + (epoch + 1) * EPOCH);
        PerformanceOracle.Report memory r = PerformanceOracle.Report({
            epoch: epoch, deskNav: desk, btcNav: btc, equityNav: eq, flipNav: flip, reportHash: h
        });
        oracle.publish(r, _sorted(keyB, keyC, r));
        PerformanceOracle.Publication memory p = oracle.getPublication(epoch);
        assertEq(p.deskNav, desk);
        assertEq(p.btcNav, btc);
        assertEq(p.equityNav, eq);
        assertEq(p.flipNav, flip);
        assertEq(p.reportHash, h);
    }
}
