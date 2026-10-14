// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeploymentConfig} from "./DeploymentConfig.sol";
import {IStrategyRegistry} from "./interfaces/IStrategyRegistry.sol";

/// @title HiveDesk trading vault
/// @notice Holds the desk's ETH trading balance. Anyone may deposit and receives shares of the desk's net
/// asset value. Only the designated strategy wallet may move funds out to trade, and only against a
/// strategy it logged in the StrategyRegistry. Depositors withdraw by burning shares whenever the vault
/// holds enough idle ETH; no account can pause, gate or seize withdrawals. There is no owner.
/// @dev Accounting: totalAssets = idle ETH + capital currently out with the strategy wallet. Capital
/// returns through `returnCapital`, which realises the trade's profit or loss. A trade that returns
/// nothing is a total loss and is settled with a zero-value `returnCapital`.
contract DeskVault {
    /// @notice The only account that can take funds out to trade. Fixed at deployment.
    address public immutable strategyWallet;

    /// @notice Registry every allocation must reference.
    IStrategyRegistry public immutable registry;

    uint256 public totalShares;
    mapping(address account => uint256 shares) public sharesOf;

    /// @notice Capital currently out with the strategy wallet, at cost.
    uint256 public deployedCapital;

    /// @notice Outstanding principal per executed strategy id. Zero once settled or never allocated.
    mapping(uint256 strategyId => uint256 principal) public outstanding;

    /// @notice True once a strategy id has been used for an allocation; an id can only be traded once.
    mapping(uint256 strategyId => bool executed) public executed;

    /// @notice Cumulative realised profit and loss, in wei, over every settled trade.
    int256 public realizedPnl;

    uint256 private _lock = 1;

    event Deposited(address indexed depositor, uint256 assets, uint256 shares);
    event Withdrawn(address indexed depositor, address indexed receiver, uint256 shares, uint256 assets);
    event Allocated(uint256 indexed strategyId, bytes32 indexed decisionHash, uint256 amount);
    event TradeSettled(uint256 indexed strategyId, uint256 principal, uint256 returned, int256 pnl);
    event Donated(address indexed from, uint256 amount);

    error NotStrategyWallet(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 idle);
    error StrategyNotOwnedByDesk(uint256 strategyId, address executor);
    error StrategyAlreadyExecuted(uint256 strategyId);
    error AllocationCapExceeded(uint256 requested, uint256 available);
    error NothingToSettle(uint256 strategyId);
    error UseReturnCapital();
    error EthTransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyStrategy() {
        if (msg.sender != strategyWallet) revert NotStrategyWallet(msg.sender);
        _;
    }

    /// @param strategyWallet_ The swarm's execution wallet. A requester-held value: see README.
    /// @param registry_ The StrategyRegistry deployed with this vault. Not called here; checked on first use.
    constructor(address strategyWallet_, address registry_) {
        if (strategyWallet_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        strategyWallet = strategyWallet_;
        registry = IStrategyRegistry(registry_);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice Idle ETH plus capital out with the strategy wallet, at cost.
    function totalAssets() public view returns (uint256) {
        return address(this).balance + deployedCapital;
    }

    /// @notice ETH held in the vault and available for withdrawals right now.
    function idleBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Shares minted for `assets` at the current NAV (rounds down).
    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * (totalShares + DeploymentConfig.SHARE_OFFSET) / (totalAssets() + 1);
    }

    /// @notice ETH owed for `shares` at the current NAV (rounds down).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets() + 1) / (totalShares + DeploymentConfig.SHARE_OFFSET);
    }

    /// @notice NAV per share in 1e18 fixed point; the number the PerformanceOracle publishes as desk NAV.
    function navPerShare() external view returns (uint256) {
        return convertToAssets(DeploymentConfig.WAD);
    }

    /// @notice Largest additional allocation the strategy wallet could take right now.
    function allocationHeadroom() public view returns (uint256) {
        uint256 cap = totalAssets() * DeploymentConfig.MAX_ALLOCATION_BPS / DeploymentConfig.BPS;
        return cap > deployedCapital ? cap - deployedCapital : 0;
    }

    // ------------------------------------------------------------------------------------------------
    // Depositors
    // ------------------------------------------------------------------------------------------------

    /// @notice Deposits ETH and mints shares to the caller.
    function deposit() external payable nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        // msg.value is already part of address(this).balance, so price against the balance before it.
        uint256 assetsBefore = address(this).balance - msg.value + deployedCapital;
        shares = msg.value * (totalShares + DeploymentConfig.SHARE_OFFSET) / (assetsBefore + 1);
        if (shares == 0) revert ZeroShares();
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        emit Deposited(msg.sender, msg.value, shares);
    }

    /// @notice Burns `shares` and sends the ETH they are worth to `receiver`. Never gated by anyone;
    /// reverts only when the vault does not hold enough idle ETH for this amount.
    function withdraw(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();
        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert InsufficientShares(shares, held);
        assets = convertToAssets(shares);
        uint256 idle = address(this).balance;
        if (assets > idle) revert InsufficientLiquidity(assets, idle);

        sharesOf[msg.sender] = held - shares;
        totalShares -= shares;
        emit Withdrawn(msg.sender, receiver, shares, assets);

        (bool ok,) = receiver.call{value: assets}("");
        if (!ok) revert EthTransferFailed();
    }

    // ------------------------------------------------------------------------------------------------
    // Strategy wallet
    // ------------------------------------------------------------------------------------------------

    /// @notice Moves `amount` of idle ETH to the strategy wallet to execute `strategyId`.
    /// @dev The strategy must have been proposed in the registry by the strategy wallet itself and must
    /// not have been executed before. Total capital out may not exceed MAX_ALLOCATION_BPS of total assets.
    function allocate(uint256 strategyId, uint256 amount) external nonReentrant onlyStrategy {
        if (amount == 0) revert ZeroAmount();
        IStrategyRegistry.Strategy memory s = registry.get(strategyId);
        if (s.executor != strategyWallet) revert StrategyNotOwnedByDesk(strategyId, s.executor);
        if (executed[strategyId]) revert StrategyAlreadyExecuted(strategyId);
        uint256 headroom = allocationHeadroom();
        if (amount > headroom) revert AllocationCapExceeded(amount, headroom);
        if (amount > address(this).balance) revert InsufficientLiquidity(amount, address(this).balance);

        executed[strategyId] = true;
        outstanding[strategyId] = amount;
        deployedCapital += amount;
        emit Allocated(strategyId, s.decisionHash, amount);

        (bool ok,) = strategyWallet.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Returns the proceeds of `strategyId` and realises its profit or loss. Send the full
    /// proceeds as msg.value; zero settles a total loss.
    function returnCapital(uint256 strategyId) external payable nonReentrant onlyStrategy {
        uint256 principal = outstanding[strategyId];
        if (principal == 0) revert NothingToSettle(strategyId);
        outstanding[strategyId] = 0;
        deployedCapital -= principal;
        int256 pnl = int256(msg.value) - int256(principal);
        realizedPnl += pnl;
        emit TradeSettled(strategyId, principal, msg.value, pnl);
    }

    /// @notice Plain ETH sent to the vault is a donation to all shareholders. The strategy wallet must
    /// settle through `returnCapital` so capital out is accounted for.
    receive() external payable {
        if (msg.sender == strategyWallet) revert UseReturnCapital();
        emit Donated(msg.sender, msg.value);
    }
}
