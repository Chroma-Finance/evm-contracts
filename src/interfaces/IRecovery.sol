// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the social recovery module.
interface IRecovery {
    /// @notice Vault owner configures the guardian set and approval threshold.
    /// @param vault     The vault to configure recovery for.
    /// @param guardians Array of guardian addresses (max 5).
    /// @param threshold Minimum approvals required (min 2, max guardians.length).
    function setRecoveryConfig(address vault, address[] calldata guardians, uint256 threshold) external;

    /// @notice A registered guardian initiates the recovery process.
    /// @param vault    The vault to recover.
    /// @param newOwner The proposed new owner address.
    function initiateRecovery(address vault, address newOwner) external;

    /// @notice A registered guardian casts an approval vote for the active recovery.
    /// @param vault The vault whose active recovery to approve.
    function approveRecovery(address vault) external;

    /// @notice Executes ownership transfer after timelock and threshold are satisfied.
    /// @return success  Whether the recovery was executed.
    /// @return newOwner The new vault owner.
    function executeRecovery(address vault) external returns (bool success, address newOwner);

    /// @notice Current vault owner cancels the active recovery during the timelock window.
    /// @param vault The vault whose active recovery to cancel.
    function vetoRecovery(address vault) external;

    /// @notice Returns whether the given address is a registered guardian for the vault.
    function isGuardian(address vault, address guardian) external view returns (bool);
}
