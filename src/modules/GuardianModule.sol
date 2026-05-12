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
 * @dev Guardians sign withdrawal approvals off-chain. Users include signatures
 *      in withdrawal transactions for on-chain validation.
 */
contract GuardianModule is IGuardian, EIP712, Ownable {
    bytes32 public constant WITHDRAWAL_APPROVAL_TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    /// @notice Guardian address per vault.
    mapping(address => address) public guardians;

    /// @notice Nonce per vault per owner (replay protection).
    mapping(address => mapping(address => uint256)) public nonces;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InvalidSignature();
    error SignatureExpired();
    error Unauthorized();
    error ZeroAddress();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() EIP712("Chroma Guardian", "1") Ownable(msg.sender) {}

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Set guardian for a vault (or disable by setting address(0)).
     * @dev Callable by the vault owner directly, or by the vault contract itself.
     *      The vault checks its own authorization before calling (e.g. from setGuardianAddress),
     *      so msg.sender == vault is treated as a pre-authorized call.
     * @param vault    The vault address
     * @param guardian The guardian address (or address(0) to disable)
     */
    function setGuardian(address vault, address guardian) external {
        if (msg.sender == vault) {
            // Vault has already checked authorization internally (owner or recoveryModule).
            guardians[vault] = guardian;
            emit GuardianSet(vault, guardian);
            return;
        }
        if (IVault(vault).owner() != msg.sender) revert Unauthorized();
        guardians[vault] = guardian;
        emit GuardianSet(vault, guardian);
    }

    /**
     * @notice Validate guardian signature for a withdrawal.
     * @dev Uses EIP-712 typed data signatures. Increments nonce on success.
     *      Returns true immediately if no guardian is set (auto-approve).
     *      Returns false (not revert) on expired deadline or bad signature.
     * @param vault     Vault address
     * @param owner     Withdrawal initiator
     * @param amount    Withdrawal amount
     * @param recipient Funds recipient
     * @param deadline  Signature expiry timestamp
     * @param signature EIP-712 signature from guardian
     * @return True if approved
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

        uint256 nonce = nonces[vault][owner];
        bytes32 structHash = keccak256(abi.encode(
            WITHDRAWAL_APPROVAL_TYPEHASH,
            vault,
            owner,
            amount,
            recipient,
            nonce,
            deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != guardian) return false;

        nonces[vault][owner]++;
        return true;
    }

    /// @notice Returns current nonce for a vault/owner pair.
    function getNonce(address vault, address owner) external view returns (uint256) {
        return nonces[vault][owner];
    }

    /// @notice Returns the EIP-712 domain separator.
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
