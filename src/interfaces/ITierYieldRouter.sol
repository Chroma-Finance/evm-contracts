// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for a per-tier Boost routing gateway that maps portfolio assets to
///         single-asset yield strategies (see {ISingleAssetYieldStrategy}).
interface ITierYieldRouter {
    /// @notice Returns the strategy configured for `asset`, or address(0) if uncovered.
    function strategyOf(address asset) external view returns (address);

    /// @notice Deposits `amount` of `asset` on behalf of the calling vault into its configured
    ///         strategy. Reverts if `asset` has no strategy configured.
    /// @dev Caller must approve this contract for `amount` first.
    function deposit(address asset, uint256 amount) external;

    /// @notice Withdraws the calling vault's entire strategy position in `asset` and returns
    ///         the underlying amount transferred back to the caller.
    function withdrawAll(address asset) external returns (uint256 amount);

    /// @notice Returns `vault`'s proportional value in `asset`, or 0 if `asset` is uncovered.
    function valueOf(address vault, address asset) external view returns (uint256);

    /// @notice Authorizes a vault to call {deposit} and {withdrawAll}.
    function registerVault(address vault) external;
}
