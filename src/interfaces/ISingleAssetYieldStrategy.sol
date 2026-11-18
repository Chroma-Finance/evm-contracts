// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for a single-asset yield strategy, deployed into by one or more
///         {ITierYieldRouter} instances on behalf of many vaults sharing the same underlying asset.
interface ISingleAssetYieldStrategy {
    /// @notice Returns the single underlying asset this strategy deploys.
    function asset() external view returns (address);

    /// @notice Deposits `amount` of the underlying asset for `vault` and mints strategy shares.
    /// @dev Caller must be an authorized router that has already pulled `amount` from `vault`
    ///      and approved this contract for it.
    function deposit(address vault, uint256 amount) external returns (uint256 shares);

    /// @notice Redeems 100% of `vault`'s strategy shares and returns the underlying amount.
    function withdrawAll(address vault) external returns (uint256 amount);

    /// @notice Returns `vault`'s proportional value of the underlying asset.
    function valueOf(address vault) external view returns (uint256);

    /// @notice Authorizes a router to call {deposit} and {withdrawAll} on behalf of vaults.
    function registerRouter(address router) external;
}
