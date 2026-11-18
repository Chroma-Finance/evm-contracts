// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @notice Minimal interface to the Uniswap V3 NonfungiblePositionManager.
 * @dev Deliberately does NOT import `@uniswap/v3-periphery`'s own
 *      INonfungiblePositionManager.sol: that file inherits IERC721Metadata /
 *      IERC721Enumerable / IERC721Permit against OpenZeppelin 3.4.2's ERC721 import
 *      paths (`token/ERC721/IERC721Metadata.sol` etc.), which no longer exist in this
 *      repo's vendored OpenZeppelin v5 (moved under `token/ERC721/extensions/`). Only the
 *      functions {UniswapV3LPStrategy} actually calls are declared here; the ABI matches
 *      the real deployed contract exactly, so it is safe to cast the on-chain address to
 *      this interface.
 */
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96  nonce,
            address operator,
            address token0,
            address token1,
            uint24  fee,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
