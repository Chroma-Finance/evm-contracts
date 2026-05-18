// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the gasless guardian module using EIP-712 off-chain signatures.
interface IGuardian {
    /// @notice Returns the guardian EOA set for a vault (address(0) = disabled).
    function guardians(address vault) external view returns (address);

    /// @notice Returns the current withdrawal nonce for a vault/owner pair.
    function nonces(address vault, address owner) external view returns (uint256);

    /// @notice Returns the current guardian-change nonce for a vault.
    function guardianChangeNonces(address vault) external view returns (uint256);

    /**
     * @notice Set or change the guardian EOA for a vault.
     *
     * Path 1 — no guardian set: owner calls freely, `signature` ignored.
     * Path 2 — vault calls (social recovery): unconditionally trusted, `signature` ignored.
     * Path 3 — guardian already set, owner calls: requires EIP-712 GuardianUpdate signature
     *           from the *current* guardian approving `newGuardian`.
     *           Pass address(0) as `newGuardian` to renounce.
     */
    function setGuardian(address vault, address newGuardian, bytes calldata signature) external;

    /// @notice Validates an EIP-712 guardian signature for a withdrawal. Increments nonce on success.
    function validateWithdrawal(
        address vault,
        address owner,
        uint256 amount,
        address recipient,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bool);

    /// @notice Returns the current withdrawal nonce for a vault/owner pair.
    function getNonce(address vault, address owner) external view returns (uint256);

    /// @notice Returns the EIP-712 domain separator.
    function getDomainSeparator() external view returns (bytes32);

    event GuardianSet(address indexed vault, address indexed guardian);
}
