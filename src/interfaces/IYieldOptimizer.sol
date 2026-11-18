// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for the Chroma Finance Boost module (yield optimizer).
interface IYieldOptimizer {
    /// @notice Deposits portfolio token amounts and mints shares to the caller.
    /// @dev Caller must be an authorized vault and must approve this contract for each amount first.
    function deposit(uint256[] calldata amounts) external returns (uint256 sharesMinted);

    /// @notice Burns `shares` and returns the underlying token amounts to the caller.
    function withdraw(uint256 shares) external returns (uint256[] memory amountsOut);

    /// @notice Returns the total deployed amount of each underlying asset held by the strategy.
    function totalAssets() external view returns (uint256[] memory);

    /// @notice Returns `vault`'s proportional share of each underlying asset.
    function valueOf(address vault) external view returns (uint256[] memory);

    /// @notice Returns the Boost shares held by `vault`.
    function sharesOf(address vault) external view returns (uint256);

    /// @notice Returns the ordered list of underlying asset tokens.
    function assets() external view returns (address[] memory);

    /// @notice Permissionlessly claims yield, skims the boost fee, and re-deploys the remainder.
    function harvest() external;

    /// @notice Pulls 100% of deployed assets back into this contract. Owner only.
    function emergencyWithdrawAll() external;

    /// @notice Authorizes a vault to deposit/withdraw. Factory only.
    function registerVault(address vault) external;

    /// @notice Returns true if deposits are currently paused.
    function paused() external view returns (bool);
}
