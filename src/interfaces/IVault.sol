// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Core interface for Chroma Finance portfolio vaults.
interface IVault {
    function owner() external view returns (address);
    function riskTier() external view returns (uint8);
    function guardianModule() external view returns (address);
    function recoveryModule() external view returns (address);
    function totalAssets() external view returns (uint256);

    /// @notice Deposit any whitelisted token; only callable by vault owner.
    function deposit(address inputToken, uint256 amount) external returns (uint256 shares);

    /// @notice Withdraw by burning shares; only callable by vault owner.
    function withdraw(address outputToken, uint256 shares, uint256 deadline, bytes calldata signature) external returns (uint256 usdValue);

    /// @notice Transfer ownership via social recovery module only.
    function transferOwnershipFromRecovery(address newOwner) external;

    /// @notice Rotate the guardian address via guardian module.
    function setGuardianAddress(address newGuardian) external;
}
