// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SwapRouter
 * @notice Thin wrapper around Uniswap V3's {ISwapRouter} for one-time entry and exit swaps.
 *
 *         Strategy: buy-and-hold — swaps only happen on vault deposit (denomination asset →
 *         portfolio tokens) and on vault withdrawal (portfolio tokens → denomination asset).
 *         No rebalancing swaps are ever triggered.
 *
 *         Callers must approve this contract before calling any swap function.
 *         Output tokens are sent directly to the caller.
 *
 *         Pool fee tiers on Uniswap V3:
 *         - 100   = 0.01% (stable pairs)
 *         - 500   = 0.05% (highly liquid pairs)
 *         - 3000  = 0.30% (most token pairs)
 *         - 10000 = 1.00% (exotic pairs)
 */
contract SwapRouter is Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10% hard cap

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice The Uniswap V3 SwapRouter (deployed at a fixed address per chain).
    ISwapRouter public immutable uniswapRouter;

    /// @notice Default slippage tolerance in basis points (50 = 0.5%).
    uint256 public defaultSlippage = 50;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event SlippageUpdated(uint256 newSlippageBps);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidSlippage();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param uniswapRouter_ Uniswap V3 SwapRouter address for the target chain.
    constructor(address uniswapRouter_) Ownable(msg.sender) {
        if (uniswapRouter_ == address(0)) revert ZeroAddress();
        uniswapRouter = ISwapRouter(uniswapRouter_);
    }

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Swaps an exact amount of `tokenIn` for as much `tokenOut` as possible
     *         via a single Uniswap V3 pool.
     * @dev Use this when a direct tokenIn/tokenOut pool exists (most liquid pairs).
     *      Caller must approve this contract for `amountIn` of `tokenIn` first.
     * @param tokenIn      Input token address.
     * @param tokenOut     Output token address.
     * @param fee          Uniswap V3 pool fee tier (100, 500, 3000, or 10000).
     * @param amountIn     Exact amount of `tokenIn` to spend.
     * @param minAmountOut Minimum acceptable output; reverts if Uniswap returns less.
     * @return amountOut   Actual amount of `tokenOut` received.
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           tokenIn,
            tokenOut:          tokenOut,
            fee:               fee,
            recipient:         msg.sender,
            deadline:          block.timestamp,
            amountIn:          amountIn,
            amountOutMinimum:  minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = uniswapRouter.exactInputSingle(params);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Swaps an exact amount of the first token in `path` for as much of the
     *         last token as possible, routing through intermediate pools.
     * @dev Use this for tokens without a direct pool (e.g., PAXG → WBTC via USDC).
     *      Path format: abi.encodePacked(tokenIn, fee0, token1, fee1, ..., tokenOut).
     *      Caller must approve this contract for `amountIn` of the input token first.
     * @param path         ABI-packed swap path (addresses interleaved with uint24 fees).
     * @param tokenIn      First token in the path (used for the safeTransferFrom).
     * @param tokenOut     Last token in the path (used for event emission).
     * @param amountIn     Exact amount of `tokenIn` to spend.
     * @param minAmountOut Minimum acceptable output; reverts if Uniswap returns less.
     * @return amountOut   Actual amount of `tokenOut` received.
     */
    function swapExactInputMultihop(
        bytes calldata path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path:             path,
            recipient:        msg.sender,
            deadline:         block.timestamp,
            amountIn:         amountIn,
            amountOutMinimum: minAmountOut
        });

        amountOut = uniswapRouter.exactInput(params);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Calculates the minimum acceptable output for a given input and slippage.
     * @param amountIn   Gross input amount.
     * @param slippageBps Slippage tolerance in basis points (e.g., 50 = 0.5%).
     * @return Minimum amount that must be received to not revert.
     */
    function calculateMinAmountOut(uint256 amountIn, uint256 slippageBps) public pure returns (uint256) {
        return amountIn * (BPS_DENOMINATOR - slippageBps) / BPS_DENOMINATOR;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /**
     * @notice Updates the default slippage tolerance.
     * @param slippageBps New slippage in basis points. Cannot exceed {MAX_SLIPPAGE_BPS}.
     */
    function setSlippage(uint256 slippageBps) external onlyOwner {
        if (slippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
        defaultSlippage = slippageBps;
        emit SlippageUpdated(slippageBps);
    }
}
