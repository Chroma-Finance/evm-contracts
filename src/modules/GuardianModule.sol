// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IGuardian} from "../interfaces/IGuardian.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title GuardianModule
 * @notice Two-party withdrawal protection: the vault owner requests a withdrawal,
 *         the guardian approves it, and the vault consumes the approval during execution.
 *
 *         Guardian removal enforces a 7-day delay to prevent owners from immediately
 *         bypassing protection after a compromise.
 *
 *         Optional daily limits allow small withdrawals to bypass guardian approval,
 *         providing a better UX for routine operations.
 */
contract GuardianModule is IGuardian {
    // ─── Types ───────────────────────────────────────────────────────────────

    struct GuardianConfig {
        address guardian;
        uint256 pendingRemovalAt; // timestamp; 0 = no removal pending
    }

    struct WithdrawalRequest {
        uint256 amount;
        address recipient;
        uint256 requestTime;
        bool    approved;
        bool    executed;
    }

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant REQUEST_TIMEOUT     = 24 hours;
    uint256 public constant GUARDIAN_REMOVAL_DELAY = 7 days;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice vault → guardian configuration.
    mapping(address => GuardianConfig) public guardianConfigs;

    /// @notice vault → owner → active withdrawal request.
    mapping(address => mapping(address => WithdrawalRequest)) public requests;

    /// @notice Optional daily limit (denomination asset units); 0 = disabled.
    mapping(address => uint256) public dailyLimits;
    mapping(address => uint256) public dailyWithdrawn;
    mapping(address => uint256) public lastWithdrawalDay;

    // ─── Events ──────────────────────────────────────────────────────────────

    event GuardianSet(address indexed vault, address indexed guardian);
    event GuardianRemovalInitiated(address indexed vault, address indexed guardian, uint256 effectiveAt);
    event GuardianRemovalExecuted(address indexed vault);
    event WithdrawalRequested(address indexed vault, address indexed owner, uint256 amount, address recipient);
    event WithdrawalApproved(address indexed vault, address indexed guardian, uint256 amount);
    event WithdrawalExecuted(address indexed vault, uint256 amount);
    event DailyLimitSet(address indexed vault, uint256 limit);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error RequestAlreadyActive();
    error NoActiveRequest();
    error RequestExpired();
    error AlreadyApproved();
    error NotApproved();
    error RemovalDelayPending();
    error NoRemovalPending();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyVaultOwner(address vault) {
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyGuardian(address vault) {
        if (guardianConfigs[vault].guardian != msg.sender) revert Unauthorized();
        _;
    }

    // ─── Guardian management ─────────────────────────────────────────────────

    /**
     * @notice Sets the guardian for a vault. Can only be called when no guardian is currently set.
     * @dev To replace a guardian, first call {initiateGuardianRemoval} and wait 7 days.
     */
    function setGuardian(address vault, address guardian) external onlyVaultOwner(vault) {
        if (guardian == address(0)) revert ZeroAddress();
        GuardianConfig storage config = guardianConfigs[vault];
        // Allow setting if no guardian exists or removal has been executed.
        require(config.guardian == address(0), "Use removal process to replace guardian");
        config.guardian = guardian;
        emit GuardianSet(vault, guardian);
    }

    /**
     * @notice Starts the 7-day countdown to remove the current guardian.
     * @dev The owner may cancel by immediately setting a new guardian after removal executes.
     */
    function initiateGuardianRemoval(address vault) external onlyVaultOwner(vault) {
        GuardianConfig storage config = guardianConfigs[vault];
        if (config.guardian == address(0)) revert NoActiveRequest();
        config.pendingRemovalAt = block.timestamp + GUARDIAN_REMOVAL_DELAY;
        emit GuardianRemovalInitiated(vault, config.guardian, config.pendingRemovalAt);
    }

    /// @notice Finalises guardian removal after the 7-day delay has elapsed.
    function executeGuardianRemoval(address vault) external onlyVaultOwner(vault) {
        GuardianConfig storage config = guardianConfigs[vault];
        if (config.pendingRemovalAt == 0) revert NoRemovalPending();
        if (block.timestamp < config.pendingRemovalAt) revert RemovalDelayPending();
        config.guardian = address(0);
        config.pendingRemovalAt = 0;
        emit GuardianRemovalExecuted(vault);
    }

    // ─── Withdrawal flow ─────────────────────────────────────────────────────

    /**
     * @notice Owner creates a withdrawal request. Auto-approved if amount is within daily limit.
     * @param vault     The vault to withdraw from.
     * @param amount    Amount of denomination asset to withdraw.
     * @param recipient Address to receive the withdrawn funds.
     */
    function requestWithdrawal(
        address vault,
        uint256 amount,
        address recipient
    ) external override onlyVaultOwner(vault) {
        if (amount == 0)    revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        WithdrawalRequest storage existing = requests[vault][msg.sender];
        if (existing.amount != 0 && !existing.executed) revert RequestAlreadyActive();

        bool withinDailyLimit = _isWithinDailyLimit(vault, amount);

        requests[vault][msg.sender] = WithdrawalRequest({
            amount:      amount,
            recipient:   recipient,
            requestTime: block.timestamp,
            approved:    withinDailyLimit,
            executed:    false
        });

        emit WithdrawalRequested(vault, msg.sender, amount, recipient);
        if (withinDailyLimit) {
            emit WithdrawalApproved(vault, address(0), amount); // address(0) = auto-approved
        }
    }

    /**
     * @notice Guardian approves a pending withdrawal request.
     * @param vault  The vault whose request to approve.
     * @param owner  The vault owner who submitted the request.
     */
    function approveWithdrawal(
        address vault,
        address owner
    ) external override onlyGuardian(vault) {
        WithdrawalRequest storage req = requests[vault][owner];
        if (req.amount == 0 || req.executed) revert NoActiveRequest();
        if (block.timestamp > req.requestTime + REQUEST_TIMEOUT) revert RequestExpired();
        if (req.approved) revert AlreadyApproved();

        req.approved = true;
        emit WithdrawalApproved(vault, msg.sender, req.amount);
    }

    /**
     * @notice Called by {PortfolioVault.withdraw} to verify and consume the guardian approval.
     * @dev msg.sender must be the vault itself.
     * @return approved Whether the withdrawal is permitted to proceed.
     * @return amount   The approved withdrawal amount.
     */
    function executeWithdrawal(address vault) external override returns (bool approved, uint256 amount) {
        // Must be called by the vault contract to prevent replay outside a real withdrawal.
        if (msg.sender != vault) revert Unauthorized();

        address owner = IVault(vault).owner();
        WithdrawalRequest storage req = requests[vault][owner];

        if (req.amount == 0 || req.executed) revert NoActiveRequest();
        if (block.timestamp > req.requestTime + REQUEST_TIMEOUT) revert RequestExpired();
        if (!req.approved) revert NotApproved();

        req.executed = true;
        amount = req.amount;

        _trackDailyWithdrawal(vault, amount);

        emit WithdrawalExecuted(vault, amount);
        return (true, amount);
    }

    // ─── Daily limits ────────────────────────────────────────────────────────

    /**
     * @notice Sets the daily withdrawal limit for a vault. 0 disables the limit (guardian always required).
     */
    function setDailyLimit(address vault, uint256 limit) external onlyVaultOwner(vault) {
        dailyLimits[vault] = limit;
        emit DailyLimitSet(vault, limit);
    }

    /// @notice Returns whether `amount` fits within the vault's remaining daily allowance.
    function checkDailyLimit(address vault, uint256 amount) external view returns (bool) {
        return _isWithinDailyLimit(vault, amount);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _isWithinDailyLimit(address vault, uint256 amount) internal view returns (bool) {
        uint256 limit = dailyLimits[vault];
        if (limit == 0) return false; // disabled — guardian always required

        uint256 today = block.timestamp / 1 days;
        uint256 alreadyWithdrawn = lastWithdrawalDay[vault] == today ? dailyWithdrawn[vault] : 0;
        return alreadyWithdrawn + amount <= limit;
    }

    function _trackDailyWithdrawal(address vault, uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        if (lastWithdrawalDay[vault] != today) {
            dailyWithdrawn[vault] = 0;
            lastWithdrawalDay[vault] = today;
        }
        dailyWithdrawn[vault] += amount;
    }
}
