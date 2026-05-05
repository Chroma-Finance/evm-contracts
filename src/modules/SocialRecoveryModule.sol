// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IRecovery} from "../interfaces/IRecovery.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title SocialRecoveryModule
 * @notice 3-of-5 guardian social recovery for lost vault keys, inspired by
 *         Vitalik Buterin's social recovery wallet design.
 *
 *         Flow:
 *         1. Owner calls {setRecoveryConfig} to register guardians and threshold.
 *         2. Any guardian calls {initiateRecovery} with a proposed new owner.
 *            The initiator's approval is counted automatically.
 *         3. Additional guardians call {approveRecovery} until threshold is met.
 *         4. After the 48-hour timelock, anyone calls {executeRecovery}.
 *         5. The current owner may {vetoRecovery} at any point during the timelock.
 *
 *         Nonce-based approval tracking: each new {initiateRecovery} call increments
 *         the vault nonce, so previous approval votes are automatically invalidated
 *         without requiring storage deletion of a mapping-inside-struct.
 */
contract SocialRecoveryModule is IRecovery {
    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_PERIOD = 48 hours;
    uint256 public constant MAX_GUARDIANS   = 5;
    uint256 public constant MIN_THRESHOLD   = 2;

    // ─── Types ───────────────────────────────────────────────────────────────

    struct RecoveryConfig {
        address[] guardians;
        uint256   threshold;
    }

    struct RecoveryRequest {
        address newOwner;
        uint256 requestTime;
        uint256 approvalCount;
        bool    executed;
        bool    vetoed;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice vault → guardian configuration set by the vault owner.
    mapping(address => RecoveryConfig) private _configs;

    /// @notice vault → active recovery request.
    mapping(address => RecoveryRequest) public requests;

    /// @notice Incremented on each new recovery initiation to invalidate stale approvals.
    mapping(address => uint256) private _nonces;

    /// @notice vault → nonce → guardian → hasApproved.
    mapping(address => mapping(uint256 => mapping(address => bool))) private _approvals;

    // ─── Events ──────────────────────────────────────────────────────────────

    event RecoveryConfigured(address indexed vault, address[] guardians, uint256 threshold);
    event RecoveryInitiated(address indexed vault, address indexed newOwner, uint256 executeAfter);
    event RecoveryApproved(address indexed vault, address indexed guardian, uint256 approvalCount);
    event RecoveryExecuted(address indexed vault, address indexed newOwner);
    event RecoveryVetoed(address indexed vault, address indexed vetoer);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();
    error InvalidConfig();
    error NoConfig();
    error RecoveryAlreadyActive();
    error RecoveryNotActive();
    error AlreadyApproved();
    error DelayNotElapsed();
    error ThresholdNotMet();

    // ─── Config ──────────────────────────────────────────────────────────────

    /**
     * @notice Sets the guardian set and approval threshold for a vault.
     * @dev Only the vault owner can configure recovery. Should be called well before
     *      key loss; guardians should be trusted contacts who do not know each other
     *      to prevent collusion (per Vitalik's social recovery design).
     * @param vault     The vault to configure.
     * @param guardians Up to {MAX_GUARDIANS} unique non-zero guardian addresses.
     * @param threshold Number of approvals required (min {MIN_THRESHOLD}).
     */
    function setRecoveryConfig(
        address vault,
        address[] calldata guardians,
        uint256 threshold
    ) external override {
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();
        if (guardians.length == 0 || guardians.length > MAX_GUARDIANS) revert InvalidConfig();
        if (threshold < MIN_THRESHOLD || threshold > guardians.length) revert InvalidConfig();

        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < guardians.length; j++) {
                if (guardians[i] == guardians[j]) revert InvalidConfig(); // no duplicates
            }
        }

        _configs[vault] = RecoveryConfig({guardians: guardians, threshold: threshold});
        emit RecoveryConfigured(vault, guardians, threshold);
    }

    // ─── Recovery flow ───────────────────────────────────────────────────────

    /**
     * @notice A registered guardian initiates recovery for a vault.
     * @dev Bumps the nonce, invalidating any approvals from a previous attempt.
     *      The initiating guardian's approval is recorded automatically.
     * @param vault    The vault to recover.
     * @param newOwner The proposed new owner. Cannot be address(0).
     */
    function initiateRecovery(address vault, address newOwner) external override {
        if (newOwner == address(0)) revert ZeroAddress();
        if (!_isGuardian(vault, msg.sender)) revert Unauthorized();

        RecoveryRequest storage req = requests[vault];
        if (req.newOwner != address(0) && !req.executed && !req.vetoed) revert RecoveryAlreadyActive();

        uint256 nonce = _nonces[vault] + 1;
        _nonces[vault] = nonce;

        requests[vault] = RecoveryRequest({
            newOwner:      newOwner,
            requestTime:   block.timestamp,
            approvalCount: 1,
            executed:      false,
            vetoed:        false
        });

        _approvals[vault][nonce][msg.sender] = true;

        emit RecoveryInitiated(vault, newOwner, block.timestamp + TIMELOCK_PERIOD);
        emit RecoveryApproved(vault, msg.sender, 1);
    }

    /**
     * @notice A registered guardian approves the active recovery request.
     * @dev Each guardian can only vote once per recovery attempt (tracked via nonce).
     * @param vault The vault with an active recovery request.
     */
    function approveRecovery(address vault) external override {
        if (!_isGuardian(vault, msg.sender)) revert Unauthorized();

        RecoveryRequest storage req = requests[vault];
        if (req.newOwner == address(0) || req.executed || req.vetoed) revert RecoveryNotActive();

        uint256 nonce = _nonces[vault];
        if (_approvals[vault][nonce][msg.sender]) revert AlreadyApproved();

        _approvals[vault][nonce][msg.sender] = true;
        req.approvalCount += 1;

        emit RecoveryApproved(vault, msg.sender, req.approvalCount);
    }

    /**
     * @notice Executes ownership transfer after the timelock and threshold are satisfied.
     * @dev Can be called by anyone once conditions are met, but typically called by a guardian.
     *      Calls {IVault.transferOwnership} which the vault permits from its registered recoveryModule.
     * @param vault The vault to finalize recovery for.
     * @return success  Always true on success (reverts on failure).
     * @return newOwner The new vault owner address.
     */
    function executeRecovery(address vault) external override returns (bool success, address newOwner) {
        RecoveryRequest storage req = requests[vault];
        if (req.newOwner == address(0) || req.executed || req.vetoed) revert RecoveryNotActive();
        if (block.timestamp < req.requestTime + TIMELOCK_PERIOD) revert DelayNotElapsed();

        RecoveryConfig storage config = _configs[vault];
        if (req.approvalCount < config.threshold) revert ThresholdNotMet();

        req.executed = true;
        newOwner = req.newOwner;

        IVault(vault).transferOwnership(newOwner);

        emit RecoveryExecuted(vault, newOwner);
        return (true, newOwner);
    }

    /**
     * @notice Current vault owner vetoes (cancels) the active recovery request.
     * @dev The owner has the full 48-hour timelock window to identify and cancel
     *      a fraudulent recovery attempt initiated by a compromised guardian.
     * @param vault The vault whose active recovery to cancel.
     */
    function vetoRecovery(address vault) external override {
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();

        RecoveryRequest storage req = requests[vault];
        if (req.newOwner == address(0) || req.executed || req.vetoed) revert RecoveryNotActive();

        req.vetoed = true;
        emit RecoveryVetoed(vault, msg.sender);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /// @notice Returns whether `guardian` is registered as a guardian for `vault`.
    function isGuardian(address vault, address guardian) external view override returns (bool) {
        return _isGuardian(vault, guardian);
    }

    /// @notice Returns whether `guardian` has already approved the current active recovery.
    function hasApproved(address vault, address guardian) external view returns (bool) {
        return _approvals[vault][_nonces[vault]][guardian];
    }

    /// @notice Returns the full recovery config for a vault.
    function getConfig(address vault) external view returns (address[] memory guardians, uint256 threshold) {
        RecoveryConfig storage config = _configs[vault];
        return (config.guardians, config.threshold);
    }

    /// @notice Returns a snapshot of the active recovery request state.
    function getRecoveryStatus(address vault) external view returns (
        address newOwner,
        uint256 requestTime,
        uint256 executeAfter,
        uint256 approvalCount,
        bool    executed,
        bool    vetoed
    ) {
        RecoveryRequest storage req = requests[vault];
        return (
            req.newOwner,
            req.requestTime,
            req.requestTime + TIMELOCK_PERIOD,
            req.approvalCount,
            req.executed,
            req.vetoed
        );
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _isGuardian(address vault, address candidate) internal view returns (bool) {
        address[] storage guardians = _configs[vault].guardians;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == candidate) return true;
        }
        return false;
    }
}
