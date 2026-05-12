// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the gasless social recovery module.
interface IRecovery {
    /// @notice Vault owner configures the guardian set and approval threshold.
    /// @param vault     The vault to configure recovery for.
    /// @param guardians Array of guardian addresses (2–5).
    /// @param threshold Minimum approvals required (min 2, max guardians.length).
    function setRecoveryConfig(address vault, address[] calldata guardians, uint256 threshold) external;

    /// @notice Guardians collectively initiate ownership recovery using off-chain EIP-712 signatures.
    /// @param vault      The vault to recover.
    /// @param newOwner   Proposed new vault owner.
    /// @param signatures Threshold-many EIP-712 guardian signatures.
    /// @return executeAfter Timestamp after which finalizeRecovery may be called.
    function executeOwnershipRecovery(
        address vault,
        address newOwner,
        bytes[] calldata signatures
    ) external returns (uint256 executeAfter);

    /// @notice Guardians collectively initiate guardian replacement using off-chain EIP-712 signatures.
    /// @param vault        The vault whose guardian to replace.
    /// @param newGuardian  Proposed new guardian address.
    /// @param signatures   Threshold-many EIP-712 guardian signatures.
    /// @return executeAfter Timestamp after which finalizeRecovery may be called.
    function executeGuardianRecovery(
        address vault,
        address newGuardian,
        bytes[] calldata signatures
    ) external returns (uint256 executeAfter);

    /// @notice Finalizes the active recovery request after the 48-hour delay.
    /// @dev Callable by anyone. Reverts if delay not elapsed or request expired (7 days).
    /// @param vault The vault to finalize recovery for.
    function finalizeRecovery(address vault) external;

    /// @notice Returns whether the given address is a registered guardian for the vault.
    function isGuardian(address vault, address guardian) external view returns (bool);
}
