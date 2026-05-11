// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the gasless guardian module using EIP-712 off-chain signatures.
interface IGuardian {
    /// @notice Returns the guardian address set for a vault.
    function guardians(address vault) external view returns (address);

    /// @notice Returns the current nonce for a vault/owner pair.
    function nonces(address vault, address owner) external view returns (uint256);

    /// @notice Sets or removes the guardian for a vault. Only callable by vault owner.
    function setGuardian(address vault, address guardian) external;

    /// @notice Validates an EIP-712 guardian signature for a withdrawal. Increments nonce on success.
    function validateWithdrawal(
        address vault,
        address owner,
        uint256 amount,
        address recipient,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bool);

    /// @notice Returns the current nonce for a vault/owner pair.
    function getNonce(address vault, address owner) external view returns (uint256);

    /// @notice Returns the EIP-712 domain separator.
    function getDomainSeparator() external view returns (bytes32);

    event GuardianSet(address indexed vault, address indexed guardian);
}
