// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the two-party withdrawal approval module.
interface IGuardian {
    /// @notice Vault owner initiates a withdrawal request.
    function requestWithdrawal(address vault, uint256 amount, address recipient) external;

    /// @notice Guardian approves a pending withdrawal request.
    function approveWithdrawal(address vault, address owner) external;

    /// @notice Called by the vault during withdraw() to verify and consume the approval.
    /// @return approved Whether the withdrawal is approved.
    /// @return amount   The approved withdrawal amount.
    function executeWithdrawal(address vault) external returns (bool approved, uint256 amount);
}
