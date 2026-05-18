// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGuardian} from "../interfaces/IGuardian.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title GuardianModule
 * @notice Gasless guardian protection using EIP-712 signatures.
 *
 *         Guardian lifecycle:
 *         1. No guardian set (address(0))  → vault owner sets freely; no signature required.
 *         2. Guardian set, caller is vault → social recovery path; vault already verified
 *            the caller is the registered recoveryModule before forwarding.
 *         3. Guardian set, caller is owner → requires EIP-712 signature from the current
 *            guardian approving the new address (or address(0) to renounce).
 *
 *         Setting guardian to address(0) disables protection and returns to state 1,
 *         allowing the owner to appoint a fresh guardian without any signature.
 */
contract GuardianModule is IGuardian, EIP712, Ownable {
    // ─── Typehashes ──────────────────────────────────────────────────────────

    bytes32 public constant WITHDRAWAL_APPROVAL_TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant GUARDIAN_UPDATE_TYPEHASH = keccak256(
        "GuardianUpdate(address vault,address newGuardian,uint256 nonce)"
    );

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Guardian EOA per vault (address(0) = disabled).
    mapping(address => address) public guardians;

    /// @notice Withdrawal approval nonce per vault per owner (replay protection).
    mapping(address => mapping(address => uint256)) public nonces;

    /// @notice Nonce for guardian change / renounce operations (per vault).
    mapping(address => uint256) public guardianChangeNonces;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InvalidSignature();
    error SignatureExpired();
    error Unauthorized();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() EIP712("Chroma Guardian", "1") Ownable(msg.sender) {}

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Set or change the guardian EOA for a vault.
     *
     * @dev Three execution paths (checked in order):
     *
     *   1. No guardian set (guardians[vault] == address(0)):
     *      Only the vault owner may call. `signature` is ignored.
     *      Used for initial setup or after a guardian has been renounced.
     *
     *   2. Called by the vault contract itself (msg.sender == vault):
     *      Unconditionally trusted — the vault's setGuardianAddress() already
     *      verified the caller is the registered recoveryModule.
     *      `signature` is ignored.
     *
     *   3. Guardian already set, called by vault owner:
     *      Requires a valid EIP-712 GuardianUpdate signature from the *current*
     *      guardian approving `newGuardian` (use address(0) to renounce).
     *      Increments guardianChangeNonces[vault] on success.
     *
     * @param vault       The vault to update.
     * @param newGuardian New guardian EOA, or address(0) to disable.
     * @param signature   Guardian EIP-712 signature (required only for path 3).
     */
    function setGuardian(address vault, address newGuardian, bytes calldata signature) external {
        address current = guardians[vault];

        // ── Path 1: initial set ──────────────────────────────────────────────
        if (current == address(0)) {
            if (IVault(vault).owner() != msg.sender) revert Unauthorized();
            guardians[vault] = newGuardian;
            emit GuardianSet(vault, newGuardian);
            return;
        }

        // ── Path 2: social recovery (vault contract is the caller) ───────────
        if (msg.sender == vault) {
            guardians[vault] = newGuardian;
            emit GuardianSet(vault, newGuardian);
            return;
        }

        // ── Path 3: owner-initiated change / renounce with guardian approval ─
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            GUARDIAN_UPDATE_TYPEHASH, vault, newGuardian, guardianChangeNonces[vault]
        )));
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != current) revert InvalidSignature();

        guardianChangeNonces[vault]++;
        guardians[vault] = newGuardian;
        emit GuardianSet(vault, newGuardian);
    }

    /**
     * @notice Validate guardian signature for a withdrawal.
     * @dev Returns true immediately if no guardian is set (auto-approve).
     *      Returns false (not revert) on expired deadline or bad signature.
     */
    function validateWithdrawal(
        address vault,
        address owner,
        uint256 amount,
        address recipient,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bool) {
        if (block.timestamp > deadline) return false;

        address guardian = guardians[vault];
        if (guardian == address(0)) return true;

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            WITHDRAWAL_APPROVAL_TYPEHASH,
            vault,
            owner,
            amount,
            recipient,
            nonces[vault][owner],
            deadline
        )));

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != guardian) return false;

        nonces[vault][owner]++;
        return true;
    }

    /// @notice Returns current withdrawal nonce for a vault/owner pair.
    function getNonce(address vault, address owner) external view returns (uint256) {
        return nonces[vault][owner];
    }

    /// @notice Returns the EIP-712 domain separator.
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
