// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStrategyRegistry {
    struct Strategy {
        bytes32 decisionHash;
        uint64 timestamp;
        address executor;
    }

    function propose(bytes32 decisionHash) external returns (uint256 id);
    function count() external view returns (uint256);
    function get(uint256 id) external view returns (Strategy memory);
    function executorOf(uint256 id) external view returns (address);
}
