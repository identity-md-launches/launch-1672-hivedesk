// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStrategyRegistry} from "./interfaces/IStrategyRegistry.sol";

/// @title HiveDesk strategy registry
/// @notice Append-only public log of every strategy an agent proposes: a sequential id, the hash of the
/// decision document, the block timestamp and the executor (the account that proposed it). Anyone may
/// append. Nothing can delete or rewrite an entry: there is no owner and no mutating function other than
/// `propose`. The DeskVault only executes trades that reference an entry proposed by its strategy wallet.
contract StrategyRegistry is IStrategyRegistry {
    Strategy[] private _strategies;

    event StrategyProposed(
        uint256 indexed id, bytes32 indexed decisionHash, address indexed executor, uint256 timestamp
    );

    error ZeroDecisionHash();
    error UnknownStrategy(uint256 id);

    /// @notice Appends a strategy. Ids start at 1 and never repeat.
    /// @param decisionHash keccak256 (or CID digest) of the full decision record kept off chain.
    function propose(bytes32 decisionHash) external returns (uint256 id) {
        if (decisionHash == bytes32(0)) revert ZeroDecisionHash();
        _strategies.push(
            Strategy({decisionHash: decisionHash, timestamp: uint64(block.timestamp), executor: msg.sender})
        );
        id = _strategies.length;
        emit StrategyProposed(id, decisionHash, msg.sender, block.timestamp);
    }

    /// @notice Number of strategies logged so far; also the highest valid id.
    function count() external view returns (uint256) {
        return _strategies.length;
    }

    function get(uint256 id) external view returns (Strategy memory) {
        if (id == 0 || id > _strategies.length) revert UnknownStrategy(id);
        return _strategies[id - 1];
    }

    function executorOf(uint256 id) external view returns (address) {
        if (id == 0 || id > _strategies.length) revert UnknownStrategy(id);
        return _strategies[id - 1].executor;
    }
}
