// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeploymentConfig} from "./DeploymentConfig.sol";

/// @title HiveDesk performance oracle
/// @notice Publishes, once per epoch, the NAV of the desk and of each benchmark, as attested by the swarm
/// oracle panel: a fixed set of ORACLE_PANEL_SIZE signers of which ORACLE_THRESHOLD must sign the same
/// EIP-712 report. Anyone may submit a report with enough signatures. A published epoch can never be
/// rewritten by anyone: there is no admin, no setter and no delete. The panel is fixed at deployment.
/// @dev Epochs share the DeskVault/BenchmarkTracker grid: epoch 0 starts at the deployment block. An
/// epoch can be published only after it has ended, so the figures describe a closed period.
contract PerformanceOracle {
    struct Report {
        uint256 epoch;
        uint256 deskNav;
        uint256 btcNav;
        uint256 equityNav;
        uint256 flipNav;
        bytes32 reportHash;
    }

    struct Publication {
        bool published;
        uint64 blockNumber;
        uint256 deskNav;
        uint256 btcNav;
        uint256 equityNav;
        uint256 flipNav;
        bytes32 reportHash;
    }

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("HiveDesk PerformanceOracle");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "Report(uint256 epoch,uint256 deskNav,uint256 btcNav,uint256 equityNav,uint256 flipNav,bytes32 reportHash)"
    );
    uint256 private constant SECP256K1_N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public immutable signer1;
    address public immutable signer2;
    address public immutable signer3;

    /// @notice First block of epoch 0.
    uint256 public immutable startBlock;

    uint256 public publishedCount;
    mapping(uint256 epoch => Publication) private _publications;

    event Published(
        uint256 indexed epoch,
        uint256 deskNav,
        uint256 btcNav,
        uint256 equityNav,
        uint256 flipNav,
        bytes32 reportHash,
        address submitter
    );

    error ZeroAddress();
    error DuplicateSigner();
    error EpochNotEnded(uint256 epoch);
    error AlreadyPublished(uint256 epoch);
    error NotEnoughSignatures(uint256 provided, uint256 required);
    error InvalidSignatureLength();
    error InvalidSignature();
    error NotPanelSigner(address recovered);
    error SignersNotAscending();
    error NotPublished(uint256 epoch);

    /// @param signer1_ Swarm oracle panel member. Requester-held value: see README.
    /// @param signer2_ Swarm oracle panel member.
    /// @param signer3_ Swarm oracle panel member.
    constructor(address signer1_, address signer2_, address signer3_) {
        if (signer1_ == address(0) || signer2_ == address(0) || signer3_ == address(0)) revert ZeroAddress();
        if (signer1_ == signer2_ || signer1_ == signer3_ || signer2_ == signer3_) revert DuplicateSigner();
        signer1 = signer1_;
        signer2 = signer2_;
        signer3 = signer3_;
        startBlock = block.number;
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    function threshold() external pure returns (uint256) {
        return DeploymentConfig.ORACLE_THRESHOLD;
    }

    function panelSize() external pure returns (uint256) {
        return DeploymentConfig.ORACLE_PANEL_SIZE;
    }

    function isPanelSigner(address account) public view returns (bool) {
        return account == signer1 || account == signer2 || account == signer3;
    }

    function epochOf(uint256 blockNumber) public view returns (uint256) {
        if (blockNumber < startBlock) return 0;
        return (blockNumber - startBlock) / DeploymentConfig.EPOCH_BLOCKS;
    }

    function epochEndBlock(uint256 epoch) public view returns (uint256) {
        return startBlock + (epoch + 1) * DeploymentConfig.EPOCH_BLOCKS;
    }

    function currentEpoch() external view returns (uint256) {
        return epochOf(block.number);
    }

    function isPublished(uint256 epoch) external view returns (bool) {
        return _publications[epoch].published;
    }

    function getPublication(uint256 epoch) external view returns (Publication memory p) {
        p = _publications[epoch];
        if (!p.published) revert NotPublished(epoch);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice EIP-712 digest a panel member signs for `r`.
    function reportDigest(Report calldata r) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(REPORT_TYPEHASH, r.epoch, r.deskNav, r.btcNav, r.equityNav, r.flipNav, r.reportHash));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ------------------------------------------------------------------------------------------------
    // Publishing
    // ------------------------------------------------------------------------------------------------

    /// @notice Publishes `r` for its epoch. `signatures` are 65-byte (r,s,v) signatures from distinct panel
    /// members, ordered by ascending signer address. Reverts if the epoch has not ended, was already
    /// published, or fewer than ORACLE_THRESHOLD valid panel signatures are supplied.
    function publish(Report calldata r, bytes[] calldata signatures) external {
        if (block.number < epochEndBlock(r.epoch)) revert EpochNotEnded(r.epoch);
        if (_publications[r.epoch].published) revert AlreadyPublished(r.epoch);
        if (signatures.length < DeploymentConfig.ORACLE_THRESHOLD) {
            revert NotEnoughSignatures(signatures.length, DeploymentConfig.ORACLE_THRESHOLD);
        }

        bytes32 digest = reportDigest(r);
        address last = address(0);
        uint256 valid;
        for (uint256 i; i < signatures.length; ++i) {
            address recovered = _recover(digest, signatures[i]);
            if (!isPanelSigner(recovered)) revert NotPanelSigner(recovered);
            if (recovered <= last) revert SignersNotAscending();
            last = recovered;
            ++valid;
        }
        if (valid < DeploymentConfig.ORACLE_THRESHOLD) {
            revert NotEnoughSignatures(valid, DeploymentConfig.ORACLE_THRESHOLD);
        }

        _publications[r.epoch] = Publication({
            published: true,
            blockNumber: uint64(block.number),
            deskNav: r.deskNav,
            btcNav: r.btcNav,
            equityNav: r.equityNav,
            flipNav: r.flipNav,
            reportHash: r.reportHash
        });
        publishedCount += 1;

        emit Published(r.epoch, r.deskNav, r.btcNav, r.equityNav, r.flipNav, r.reportHash, msg.sender);
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();
        bytes32 rr = bytes32(signature[0:32]);
        bytes32 ss = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(ss) > SECP256K1_N_DIV_2) revert InvalidSignature();
        if (v != 27 && v != 28) revert InvalidSignature();
        address recovered = ecrecover(digest, v, rr, ss);
        if (recovered == address(0)) revert InvalidSignature();
        return recovered;
    }
}
