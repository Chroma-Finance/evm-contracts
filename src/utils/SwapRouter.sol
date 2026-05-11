// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title SwapRouter
 * @notice Wraps Uniswap V3 swaps with Chainlink oracle-validated slippage protection.
 *
 *         Deposit path: swapToPortfolio() converts a single denomination token (USDC)
 *         into the vault's portfolio allocation in one call.
 *
 *         Withdrawal path: swapToInputToken() converts multiple portfolio tokens back
 *         to the denomination token in one call.
 *
 *         Both batch functions are restricted to the authorizedVault. Single-swap
 *         functions are open to any caller.
 *
 *         MEV protection: each swap enforces a maximum of {MAX_SLIPPAGE_BPS} (0.5%)
 *         deviation from the Chainlink mid-price. The swap reverts if the Uniswap
 *         fill price falls outside this band.
 */
contract SwapRouter is Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant MAX_SLIPPAGE_BPS = 50;          // 0.5%
    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint8   public constant PRICE_DECIMALS   = 8;           // Chainlink standard
    uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Uniswap V3 SwapRouter (immutable per-chain deployment).
    ISwapRouter public immutable uniswapRouter;

    /// @notice Chainlink price feeds per token (tokenAddress → feed).
    mapping(address => address) public priceFeeds;

    /// @notice Uniswap V3 pool fee tier per sorted token pair.
    mapping(bytes32 => uint24) internal _poolFees;

    /// @notice Only this vault may call the batch swap functions.
    address public authorizedVault;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event PriceFeedSet(address indexed token, address indexed feed);
    event PoolFeeSet(address indexed tokenA, address indexed tokenB, uint24 fee);
    event AuthorizedVaultSet(address indexed vault);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error SameToken();
    error Unauthorized();
    error NoPriceFeed(address token);
    error InvalidPrice(address token);
    error StalePriceFeed(address token);
    error InsufficientOutput(uint256 minRequired, uint256 received);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != authorizedVault) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param uniswapRouter_ Uniswap V3 SwapRouter address for the target chain.
    constructor(address uniswapRouter_) Ownable(msg.sender) {
        if (uniswapRouter_ == address(0)) revert ZeroAddress();
        uniswapRouter = ISwapRouter(uniswapRouter_);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Register a Chainlink price feed for a token.
    function setPriceFeed(address token, address feed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        priceFeeds[token] = feed;
        emit PriceFeedSet(token, feed);
    }

    /// @notice Set the Uniswap V3 pool fee tier for a token pair.
    /// @param fee Fee in hundredths of a bip (100=0.01%, 500=0.05%, 3000=0.3%, 10000=1%).
    function setPoolFee(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        _poolFees[_pairHash(tokenA, tokenB)] = fee;
        emit PoolFeeSet(tokenA, tokenB, fee);
    }

    /// @notice Designate the sole vault permitted to call batch swap functions.
    function setAuthorizedVault(address vault_) external onlyOwner {
        authorizedVault = vault_;
        emit AuthorizedVaultSet(vault_);
    }

    // ─── Batch swaps (vault only) ─────────────────────────────────────────────

    /**
     * @notice Swap `amountsIn[i]` of `tokenIn` into each `tokensOut[i]`.
     * @dev Caller must approve this contract for sum(amountsIn) of tokenIn.
     *      Each swap validates output against Chainlink before executing.
     */
    function swapToPortfolio(
        address tokenIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn
    ) external onlyVault returns (uint256[] memory amountsOut) {
        uint256 n = tokensOut.length;
        amountsOut = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (amountsIn[i] == 0) continue;
            amountsOut[i] = _executeOracleSwap(tokenIn, tokensOut[i], amountsIn[i]);
        }
    }

    /**
     * @notice Swap `amountsIn[i]` of each `tokensIn[i]` into `tokenOut`.
     * @dev Caller must approve this contract for each tokensIn[i] amount.
     *      Returns total tokenOut received across all swaps.
     */
    function swapToInputToken(
        address[] calldata tokensIn,
        uint256[] calldata amountsIn,
        address tokenOut
    ) external onlyVault returns (uint256 totalOut) {
        uint256 n = tokensIn.length;
        for (uint256 i = 0; i < n; i++) {
            if (amountsIn[i] == 0) continue;
            totalOut += _executeOracleSwap(tokensIn[i], tokenOut, amountsIn[i]);
        }
    }

    // ─── Single swap (public) ─────────────────────────────────────────────────

    /**
     * @notice Swap an exact amount of `tokenIn` for at least `minAmountOut` of `tokenOut`.
     * @dev Caller must approve this contract for `amountIn` of `tokenIn` first.
     *      No oracle validation — caller supplies their own `minAmountOut`.
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
     * @notice Multi-hop swap with an ABI-packed path.
     * @dev Path: abi.encodePacked(tokenIn, fee0, token1, fee1, ..., tokenOut).
     *      Caller must approve this contract for `amountIn` of the input token.
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

    // ─── View helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Oracle-based expected output for a given swap.
     * @dev Useful for off-chain quoting. Returns 0 if either feed is missing.
     */
    function getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        return _getExpectedOutput(tokenIn, tokenOut, amountIn);
    }

    /// @notice Minimum output enforced by the oracle (amountIn → oracle price × 99.5%).
    function getMinAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 expected = _getExpectedOutput(tokenIn, tokenOut, amountIn);
        return expected * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Pool fee for a token pair, defaulting to 3000 (0.3%) when not configured.
    function getPoolFee(address tokenA, address tokenB) external view returns (uint24) {
        return _getPoolFee(tokenA, tokenB);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _executeOracleSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        if (tokenIn == tokenOut) revert SameToken();

        uint256 expected = _getExpectedOutput(tokenIn, tokenOut, amountIn);
        uint256 minOut   = expected * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS) / BPS_DENOMINATOR;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           tokenIn,
            tokenOut:          tokenOut,
            fee:               _getPoolFee(tokenIn, tokenOut),
            recipient:         msg.sender,
            deadline:          block.timestamp,
            amountIn:          amountIn,
            amountOutMinimum:  minOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = uniswapRouter.exactInputSingle(params);
        if (amountOut < minOut) revert InsufficientOutput(minOut, amountOut);

        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    function _getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 expectedOut) {
        uint256 priceIn   = _getTokenPrice(tokenIn);
        uint256 priceOut  = _getTokenPrice(tokenOut);
        uint8   decIn     = IERC20Metadata(tokenIn).decimals();
        uint8   decOut    = IERC20Metadata(tokenOut).decimals();

        // valueUSD (8 dec) = amountIn * priceIn / 10^decIn
        // expectedOut      = valueUSD * 10^decOut / priceOut
        uint256 valueUSD = amountIn * priceIn / (10 ** decIn);
        expectedOut = valueUSD * (10 ** decOut) / priceOut;
    }

    function _getTokenPrice(address token) internal view returns (uint256 price) {
        address feed = priceFeeds[token];
        if (feed == address(0)) revert NoPriceFeed(token);

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = AggregatorV3Interface(feed).latestRoundData();

        if (answer <= 0)                                      revert InvalidPrice(token);
        if (updatedAt == 0 || answeredInRound < roundId)     revert StalePriceFeed(token);
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePriceFeed(token);

        price = uint256(answer);
    }

    function _getPoolFee(address tokenA, address tokenB) internal view returns (uint24 fee) {
        fee = _poolFees[_pairHash(tokenA, tokenB)];
        if (fee == 0) return 3_000; // default 0.3%
    }

    function _pairHash(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(a, b));
    }
}
