// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Core interface for Chroma Finance portfolio vaults.
interface IVault {
    function owner() external view returns (address);
    function riskTier() external view returns (uint8);
    function guardianModule() external view returns (address);
    function recoveryModule() external view returns (address);

    // ERC-4626
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // Admin
    function transferOwnership(address newOwner) external;
    function setGuardian(address guardian) external;
    function setRecovery(address recovery) external;
}
