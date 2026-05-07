// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IEventNotifier {
    function emitDeposit(address user, address vault, uint8 tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets) external;
    function emitWithdrawal(address user, address vault, uint8 tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets) external;
    function emitManagementFee(address vault, uint8 tier, uint256 feeShares, uint256 vaultTotalAssets) external;
    function emitPerformanceFee(address vault, uint8 tier, address user, uint256 feeAssets, uint256 vaultTotalAssets) external;
    function emitBoostFee(address vault, uint8 tier, uint256 feeAmount, uint256 vaultTotalAssets) external;
    function emitVaultCreated(address user, address vault, uint8 tier) external;
}
