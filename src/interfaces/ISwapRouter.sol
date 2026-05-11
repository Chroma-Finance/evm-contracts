// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Interface for Chroma Finance swap router (used by PortfolioVault).
interface IChromaSwapRouter {
    /// @notice Swap `tokenIn` into multiple `tokensOut` using oracle-validated slippage.
    /// @dev Caller must approve this contract for sum(amountsIn) of tokenIn before calling.
    function swapToPortfolio(
        address tokenIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn
    ) external returns (uint256[] memory amountsOut);

    /// @notice Swap multiple `tokensIn` into a single `tokenOut`.
    /// @dev Caller must approve this contract for each tokensIn[i] amount before calling.
    function swapToInputToken(
        address[] calldata tokensIn,
        uint256[] calldata amountsIn,
        address tokenOut
    ) external returns (uint256 totalOut);
}
