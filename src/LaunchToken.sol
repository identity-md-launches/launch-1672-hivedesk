// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HiveDesk launch token (HVD)
/// @notice Plain fixed-supply ERC-20. The whole supply of 1,000,000,000 HVD (18 decimals) is minted once
/// to the deployer in the constructor. There is no owner, no mint, no burn, no pause, no transfer fee,
/// no blocklist and no upgrade path: what is deployed is what holders get, forever.
/// @dev The contract name is `LaunchToken` because the launch manifest requires it; the token's own
/// name is "HiveDesk" and its symbol is "HVD".
contract LaunchToken {
    string public constant name = "HiveDesk";
    string public constant symbol = "HVD";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 tokens at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientAllowance(uint256 requested, uint256 available);
    error TransferToZeroAddress();
    error ApproveToZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ApproveToZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(amount, allowed);
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(amount, fromBalance);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Total supply is fixed, so no balance can exceed it and this cannot overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
