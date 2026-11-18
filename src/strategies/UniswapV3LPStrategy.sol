// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {YieldOptimizerCore} from "../modules/YieldOptimizerCore.sol";
import {SwapRouter} from "../utils/SwapRouter.sol";

/**
 * @title UniswapV3LPStrategy
 * @notice Boost strategy that deploys a two-token pair (e.g. WBTC/WETH) into a single, shared
 *         Uniswap V3 concentrated-liquidity position on behalf of all authorized vaults.
 *
 *         V1 scope — fixed range only:
 *         - `tickLower`/`tickUpper` are set once at deployment and never change.
 *         - If price moves outside the range, the position stops earning fees until a future
 *           version adds active rebalancing. No rebalancing logic exists in this contract.
 *
 *         Ratio matching (deposit, withdraw, harvest re-compound) reuses Chroma's existing
 *         {SwapRouter}: the swap amount is a small correction so the pulled-in or paid-out
 *         tokens can be supplied to the position at the ratio the pool wants at the current
 *         price, computed via {LiquidityAmounts} against the pool's own state — no Chainlink
 *         or other oracle is read directly by this contract. `getMinAmountOut` on the
 *         SwapRouter (itself oracle-backed) supplies slippage protection for that swap.
 */
contract UniswapV3LPStrategy is YieldOptimizerCore {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Uniswap V3 NonfungiblePositionManager that mints/manages the shared LP position.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Uniswap V3 pool the shared position is deployed into.
    IUniswapV3Pool public immutable pool;

    /// @notice Pool fee tier (matches `pool`'s own fee).
    uint24 public immutable poolFee;

    /// @notice Lower tick bound of the shared position. Fixed for V1, set once at deploy.
    int24 public immutable tickLower;

    /// @notice Upper tick bound of the shared position. Fixed for V1, set once at deploy.
    int24 public immutable tickUpper;

    /// @notice Chroma's existing SwapRouter, reused for ratio-matching swaps.
    SwapRouter public immutable swapRouter;

    /// @notice `pool`'s token0 (Uniswap's own address-sorted ordering).
    address public immutable token0;

    /// @notice `pool`'s token1 (Uniswap's own address-sorted ordering).
    address public immutable token1;

    /// @dev True when {YieldOptimizerCore.assetTokens}[0] equals `token0`, used to translate
    ///      between the assetTokens ordering (constructor-supplied) and the pool's token0/token1
    ///      ordering (Uniswap's address-sorted convention) without re-deriving it every call.
    bool private immutable _asset0IsToken0;

    /// @notice The shared LP position NFT id. 0 until the first deposit.
    uint256 public tokenId;

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param factory_          VaultFactory permitted to register vaults.
     * @param feeManager_       FeeManager that receives the boost fee.
     * @param assets_           [token0Asset, token1Asset] — must have exactly 2 entries.
     * @param positionManager_  Uniswap V3 NonfungiblePositionManager.
     * @param pool_             Uniswap V3 pool for the asset pair.
     * @param poolFee_          Pool fee tier, matching `pool_`.
     * @param tickLower_        Fixed lower tick bound for the shared position.
     * @param tickUpper_        Fixed upper tick bound for the shared position.
     * @param swapRouter_       Chroma's SwapRouter, used for ratio-matching swaps.
     */
    constructor(
        address factory_,
        address feeManager_,
        address[] memory assets_,
        address positionManager_,
        address pool_,
        uint24 poolFee_,
        int24 tickLower_,
        int24 tickUpper_,
        address swapRouter_
    ) YieldOptimizerCore(factory_, feeManager_, assets_) {
        if (positionManager_ == address(0) || pool_ == address(0) || swapRouter_ == address(0)) {
            revert ZeroAddress();
        }
        if (assets_.length != 2) revert ArrayLengthMismatch();

        positionManager = INonfungiblePositionManager(positionManager_);
        pool            = IUniswapV3Pool(pool_);
        poolFee         = poolFee_;
        tickLower       = tickLower_;
        tickUpper       = tickUpper_;
        swapRouter      = SwapRouter(swapRouter_);

        token0 = pool.token0();
        token1 = pool.token1();
        _asset0IsToken0 = (assets_[0] == token0);
    }

    // ─── Strategy hooks ──────────────────────────────────────────────────────

    /// @dev Ratio-matches `amounts` to the pool's current price at [tickLower, tickUpper] and
    ///      mints (first deposit) or increases the shared LP position.
    function _deploy(uint256[] calldata amounts) internal override returns (uint256 unitsAdded) {
        (uint256 amount0, uint256 amount1) = _toPoolOrder(amounts);
        (amount0, amount1) = _matchToPoolRatio(amount0, amount1);
        unitsAdded = _mintOrIncrease(amount0, amount1);
    }

    /// @dev Removes the proportional slice of liquidity, collects only that slice's principal
    ///      (leaving any accrued fees in tokensOwed for a future {_harvest} to distribute fairly
    ///      across every vault sharing the position), and ratio-matches the result back to the
    ///      pool's current price before returning.
    function _redeem(uint256 shares, uint256 priorTotalShares)
        internal
        override
        returns (uint256[] memory amountsOut)
    {
        (, , , , , , , uint128 currentLiquidity, , , , ) = positionManager.positions(tokenId);
        uint128 liquidityToRemove = uint128((uint256(currentLiquidity) * shares) / priorTotalShares);

        uint256 amount0;
        uint256 amount1;

        if (liquidityToRemove > 0) {
            (uint256 principal0, uint256 principal1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

            if (principal0 > 0 || principal1 > 0) {
                (amount0, amount1) = positionManager.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: uint128(principal0),
                        amount1Max: uint128(principal1)
                    })
                );
            }
        }

        (amount0, amount1) = _matchToPoolRatio(amount0, amount1);
        amountsOut = _toAssetOrder(amount0, amount1);
    }

    /// @dev Current position liquidity, or 0 before the first deposit.
    function _totalUnits() internal view override returns (uint256) {
        if (tokenId == 0) return 0;
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        return uint256(liquidity);
    }

    /// @dev Current position value (from liquidity, at the pool's current price) plus any
    ///      uncollected owed fees, in assetTokens order.
    function _totalAssets() internal view override returns (uint256[] memory) {
        if (tokenId == 0) return new uint256[](2);

        (, , , , , , , uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) =
            positionManager.positions(tokenId);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );

        amount0 += tokensOwed0;
        amount1 += tokensOwed1;

        return _toAssetOrder(amount0, amount1);
    }

    /// @dev Claims accumulated trading fees only (no liquidity change), skims the boost fee,
    ///      and re-deploys the net yield back into the position via the shared increase-liquidity
    ///      path used by {_deploy}.
    function _harvest() internal override {
        if (tokenId == 0) return;

        (uint256 collected0, uint256 collected1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (collected0 > 0) collected0 = _collectBoostFee(token0, collected0);
        if (collected1 > 0) collected1 = _collectBoostFee(token1, collected1);

        (collected0, collected1) = _matchToPoolRatio(collected0, collected1);
        _mintOrIncrease(collected0, collected1);
    }

    /// @dev Pulls 100% of the position's liquidity and owed fees back into this contract as
    ///      raw tokens. The (now empty) position NFT is left intact — not burned — for V1.
    function _emergencyExit() internal override {
        if (tokenId == 0) return;

        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);

        if (liquidity > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    /// @dev Mints the position on the first call (sets `tokenId`), increases it thereafter.
    ///      Shared by {_deploy} and the harvest re-compound path so the mint/increase logic
    ///      exists exactly once.
    function _mintOrIncrease(uint256 amount0, uint256 amount1) internal returns (uint256 unitsAdded) {
        if (amount0 == 0 && amount1 == 0) return 0;

        IERC20(token0).forceApprove(address(positionManager), amount0);
        IERC20(token1).forceApprove(address(positionManager), amount1);

        if (tokenId == 0) {
            (uint256 newTokenId, uint128 liquidity, , ) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: poolFee,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            tokenId    = newTokenId;
            unitsAdded = liquidity;
        } else {
            (uint128 liquidity, , ) = positionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            unitsAdded = liquidity;
        }
    }

    /// @dev Swaps whichever token is in surplus relative to the liquidity ratio the pool wants
    ///      at [tickLower, tickUpper] at the current price, so both amounts can be fully
    ///      supplied to the position. Reused by deposit, withdraw, and harvest re-compound.
    function _matchToPoolRatio(uint256 amount0, uint256 amount1) internal returns (uint256, uint256) {
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1
        );
        (uint256 needed0, uint256 needed1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity
        );

        if (amount0 > needed0 && amount1 < needed1) {
            uint256 surplus0 = amount0 - needed0;
            uint256 out      = _swap(token0, token1, surplus0);
            amount0 -= surplus0;
            amount1 += out;
        } else if (amount1 > needed1 && amount0 < needed0) {
            uint256 surplus1 = amount1 - needed1;
            uint256 out      = _swap(token1, token0, surplus1);
            amount1 -= surplus1;
            amount0 += out;
        }

        return (amount0, amount1);
    }

    /// @dev Swaps `amountIn` of `tokenIn` for `tokenOut` via Chroma's SwapRouter, using its
    ///      oracle-derived {SwapRouter.getMinAmountOut} for slippage protection. No new swap
    ///      logic — reuses the same public, oracle-backed functions the rest of the protocol
    ///      already relies on.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 minOut = swapRouter.getMinAmountOut(tokenIn, tokenOut, amountIn);
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.swapExactInputSingle(tokenIn, tokenOut, poolFee, amountIn, minOut);
    }

    /// @dev Translates assetTokens-ordered amounts into pool token0/token1 order.
    function _toPoolOrder(uint256[] memory amounts) internal view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _asset0IsToken0 ? (amounts[0], amounts[1]) : (amounts[1], amounts[0]);
    }

    /// @dev Translates pool token0/token1-ordered amounts into assetTokens order.
    function _toAssetOrder(uint256 amount0, uint256 amount1) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = _asset0IsToken0 ? (amount0, amount1) : (amount1, amount0);
    }
}
