// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IRecovery} from "../interfaces/IRecovery.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title SocialRecoveryModule
 * @notice Gasless social recovery using off-chain EIP-712 guardian signatures.
 *
 *         Flow:
 *         1. Owner calls {setRecoveryConfig} to register guardians and threshold.
 *         2. Guardians sign off-chain (no gas, no transactions) approving either:
 *            - Ownership transfer:  OwnershipRecovery(vault, newOwner, nonce)
 *            - Guardian replacement: GuardianRecovery(vault, newGuardian, nonce)
 *         3. Any caller submits threshold-many signatures in a single transaction:
 *            - {executeOwnershipRecovery} or {executeGuardianRecovery}
 *            Signatures are verified on-chain; a 48-hour timelock begins.
 *         4. After 48 hours anyone calls {finalizeRecovery} to execute the action.
 *            Recovery expires 7 days after the timelock opens (if not finalized).
 *
 *         Design decisions:
 *         - No veto function: a compromised owner wallet cannot block recovery.
 *         - Shared nonce per vault: prevents both action types being active at once.
 *         - Separate typehashes: ownership signatures cannot be reused for guardian changes.
 *         - Nonce increments only on finalization: invalidates all prior signatures.
 */
contract SocialRecoveryModule is IRecovery, EIP712 {
    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_PERIOD      = 48 hours;
    uint256 public constant MAX_RECOVERY_DURATION = 7 days;
    uint256 public constant MAX_GUARDIANS         = 5;
    uint256 public constant MIN_THRESHOLD         = 2;

    // ─── EIP-712 Typehashes ──────────────────────────────────────────────────

    bytes32 public constant OWNERSHIP_RECOVERY_TYPEHASH = keccak256(
        "OwnershipRecovery(address vault,address newOwner,uint256 nonce)"
    );

    bytes32 public constant GUARDIAN_RECOVERY_TYPEHASH = keccak256(
        "GuardianRecovery(address vault,address newGuardian,uint256 nonce)"
    );

    // ─── Types ───────────────────────────────────────────────────────────────

    enum RecoveryAction { TRANSFER_OWNERSHIP, SET_GUARDIAN }

    struct RecoveryConfig {
        address[] guardians;
        uint256   threshold;
    }

    struct RecoveryRequest {
        RecoveryAction action;
        address        targetAddress;
        uint256        executeAfter;
        uint256        nonce;
        bool           executed;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    mapping(address => RecoveryConfig)  private _configs;
    mapping(address => RecoveryRequest) public  requests;
    mapping(address => uint256)         public  nonces;

    // ─── Events ──────────────────────────────────────────────────────────────

    event RecoveryConfigured(address indexed vault, address[] guardians, uint256 threshold);
    event OwnershipRecoveryInitiated(address indexed vault, address indexed newOwner, uint256 executeAfter, uint256 sigCount);
    event GuardianRecoveryInitiated(address indexed vault, address indexed newGuardian, uint256 executeAfter, uint256 sigCount);
    event OwnershipRecoveryExecuted(address indexed vault, address indexed newOwner);
    event GuardianRecoveryExecuted(address indexed vault, address indexed newGuardian);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();
    error InvalidConfig();
    error NoConfig();
    error RecoveryAlreadyActive();
    error RecoveryNotActive();
    error RecoveryExpired();
    error DelayNotElapsed();
    error NotGuardian();
    error DuplicateSigner();
    error InsufficientSignatures();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() EIP712("Chroma Social Recovery", "1") {}

    // ─── Config ──────────────────────────────────────────────────────────────

    /**
     * @notice Sets the guardian set and approval threshold for a vault.
     * @dev Only the current vault owner can configure. Should be called during vault setup.
     * @param vault     The vault to configure.
     * @param guardians 2–5 unique, non-zero guardian addresses.
     * @param threshold Number of guardian signatures required (min 2).
     */
    function setRecoveryConfig(
        address vault,
        address[] calldata guardians,
        uint256 threshold
    ) external override {
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();
        if (guardians.length < 2 || guardians.length > MAX_GUARDIANS) revert InvalidConfig();
        if (threshold < MIN_THRESHOLD || threshold > guardians.length) revert InvalidConfig();

        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < guardians.length; j++) {
                if (guardians[i] == guardians[j]) revert InvalidConfig();
            }
        }

        _configs[vault] = RecoveryConfig({guardians: guardians, threshold: threshold});
        emit RecoveryConfigured(vault, guardians, threshold);
    }

    // ─── Recovery execution ──────────────────────────────────────────────────

    /**
     * @notice Initiates ownership transfer by submitting threshold-many guardian signatures.
     * @dev Signatures must be EIP-712 OwnershipRecovery structs for the current nonce.
     *      Starts a 48-hour delay before {finalizeRecovery} can be called.
     *      Cannot be called while another recovery is active (unless the active one expired).
     * @param vault      The vault to recover.
     * @param newOwner   Proposed new vault owner. Cannot be address(0).
     * @param signatures Guardian EIP-712 signatures (at least threshold-many, no duplicates).
     * @return executeAfter Timestamp when finalization becomes available.
     */
    function executeOwnershipRecovery(
        address vault,
        address newOwner,
        bytes[] calldata signatures
    ) external override returns (uint256 executeAfter) {
        if (newOwner == address(0)) revert ZeroAddress();

        RecoveryConfig storage config = _configs[vault];
        if (config.guardians.length == 0) revert NoConfig();
        if (signatures.length < config.threshold) revert InsufficientSignatures();

        _requireNoActiveRecovery(vault);

        uint256 nonce = nonces[vault];
        _verifySignatures(vault, newOwner, nonce, OWNERSHIP_RECOVERY_TYPEHASH, signatures);

        executeAfter = block.timestamp + TIMELOCK_PERIOD;
        requests[vault] = RecoveryRequest({
            action:        RecoveryAction.TRANSFER_OWNERSHIP,
            targetAddress: newOwner,
            executeAfter:  executeAfter,
            nonce:         nonce,
            executed:      false
        });

        emit OwnershipRecoveryInitiated(vault, newOwner, executeAfter, signatures.length);
    }

    /**
     * @notice Initiates guardian replacement by submitting threshold-many guardian signatures.
     * @dev Signatures must be EIP-712 GuardianRecovery structs for the current nonce.
     *      Starts a 48-hour delay before {finalizeRecovery} can be called.
     * @param vault        The vault whose guardian to replace.
     * @param newGuardian  Proposed new guardian address. Cannot be address(0).
     * @param signatures   Guardian EIP-712 signatures (at least threshold-many, no duplicates).
     * @return executeAfter Timestamp when finalization becomes available.
     */
    function executeGuardianRecovery(
        address vault,
        address newGuardian,
        bytes[] calldata signatures
    ) external override returns (uint256 executeAfter) {
        if (newGuardian == address(0)) revert ZeroAddress();

        RecoveryConfig storage config = _configs[vault];
        if (config.guardians.length == 0) revert NoConfig();
        if (signatures.length < config.threshold) revert InsufficientSignatures();

        _requireNoActiveRecovery(vault);

        uint256 nonce = nonces[vault];
        _verifySignatures(vault, newGuardian, nonce, GUARDIAN_RECOVERY_TYPEHASH, signatures);

        executeAfter = block.timestamp + TIMELOCK_PERIOD;
        requests[vault] = RecoveryRequest({
            action:        RecoveryAction.SET_GUARDIAN,
            targetAddress: newGuardian,
            executeAfter:  executeAfter,
            nonce:         nonce,
            executed:      false
        });

        emit GuardianRecoveryInitiated(vault, newGuardian, executeAfter, signatures.length);
    }

    /**
     * @notice Finalizes the active recovery request after the 48-hour delay.
     * @dev Callable by anyone once the delay has elapsed.
     *      Reverts if the request has expired (older than 7 days past the unlock time).
     *      Increments the vault nonce on success, invalidating all prior guardian signatures.
     * @param vault The vault to finalize recovery for.
     */
    function finalizeRecovery(address vault) external override {
        RecoveryRequest storage req = requests[vault];
        if (req.targetAddress == address(0)) revert RecoveryNotActive();
        if (req.executed) revert RecoveryNotActive();
        if (block.timestamp < req.executeAfter) revert DelayNotElapsed();
        if (block.timestamp > req.executeAfter + MAX_RECOVERY_DURATION) revert RecoveryExpired();

        req.executed = true;
        nonces[vault]++;

        if (req.action == RecoveryAction.TRANSFER_OWNERSHIP) {
            IVault(vault).transferOwnership(req.targetAddress);
            emit OwnershipRecoveryExecuted(vault, req.targetAddress);
        } else {
            IVault(vault).setGuardianAddress(req.targetAddress);
            emit GuardianRecoveryExecuted(vault, req.targetAddress);
        }
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /// @notice Returns whether `guardian` is registered for `vault`.
    function isGuardian(address vault, address guardian) external view override returns (bool) {
        return _isGuardian(vault, guardian);
    }

    /// @notice Returns the full recovery config for a vault.
    function getConfig(address vault) external view returns (address[] memory guardians, uint256 threshold) {
        RecoveryConfig storage config = _configs[vault];
        return (config.guardians, config.threshold);
    }

    /// @notice Returns a snapshot of the active recovery request.
    function getRecoveryStatus(address vault) external view returns (
        RecoveryAction action,
        address        targetAddress,
        uint256        executeAfter,
        bool           executed,
        bool           expired
    ) {
        RecoveryRequest storage req = requests[vault];
        bool isExpired = req.targetAddress != address(0) &&
            !req.executed &&
            block.timestamp > req.executeAfter + MAX_RECOVERY_DURATION;
        return (req.action, req.targetAddress, req.executeAfter, req.executed, isExpired);
    }

    /// @notice Returns the EIP-712 domain separator.
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @dev Reverts if there is an active (non-expired, non-executed) recovery request.
    function _requireNoActiveRecovery(address vault) internal view {
        RecoveryRequest storage req = requests[vault];
        bool canOverride = req.targetAddress == address(0) ||
            req.executed ||
            block.timestamp > req.executeAfter + MAX_RECOVERY_DURATION;
        if (!canOverride) revert RecoveryAlreadyActive();
    }

    /**
     * @dev Verifies that `signatures` contains at least threshold unique valid guardian signatures
     *      for the EIP-712 struct (typehash, vault, target, nonce). Reverts on any failure.
     */
    function _verifySignatures(
        address vault,
        address target,
        uint256 nonce,
        bytes32 typehash,
        bytes[] calldata signatures
    ) internal view {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(typehash, vault, target, nonce))
        );
        address[] memory signers = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!_isGuardian(vault, signer)) revert NotGuardian();

            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == signer) revert DuplicateSigner();
            }

            signers[i] = signer;
        }
    }

    function _isGuardian(address vault, address candidate) internal view returns (bool) {
        address[] storage guardians = _configs[vault].guardians;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == candidate) return true;
        }
        return false;
    }
}
