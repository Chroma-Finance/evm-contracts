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
 *         Deposit path: swapToPortfolio() converts a user-supplied input token into the
 *         vault's portfolio allocation in one call.
 *
 *         Withdrawal path: swapToInputToken() converts multiple portfolio tokens back to
 *         a single user-requested output token in one call.
 *
 *         Security:
 *         - Batch functions restricted to authorized vaults (registered by the factory).
 *         - Input tokens (deposit) and output tokens (withdrawal) must be whitelisted.
 *         - Each swap enforces a maximum of MAX_SLIPPAGE_BPS (0.5%) deviation from the
 *           Chainlink mid-price, blocking sandwich attacks.
 */
contract SwapRouter is Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant MAX_SLIPPAGE_BPS        = 50;
    uint256 public constant BPS_DENOMINATOR         = 10_000;
    uint8   public constant PRICE_DECIMALS          = 8;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Uniswap V3 SwapRouter (immutable per-chain deployment).
    ISwapRouter public immutable uniswapRouter;

    /// @notice Chainlink price feeds per token.
    mapping(address => address) public priceFeeds;

    /// @notice Uniswap V3 pool fee tier per sorted token pair.
    mapping(bytes32 => uint24) internal _poolFees;

    /// @notice ABI-packed Uniswap V3 multi-hop path per directed (tokenIn, tokenOut) pair.
    ///         Non-empty → use exactInput; empty → fall back to exactInputSingle.
    mapping(bytes32 => bytes) private _swapPaths;

    /// @notice VaultFactory allowed to register new vaults via authorizeVault().
    address public factory;

    /// @notice Vaults authorized to call the batch swap functions.
    mapping(address => bool) public authorizedVaults;

    /// @notice Tokens accepted as deposit input (swapToPortfolio tokenIn) or
    ///         withdrawal output (swapToInputToken tokenOut).
    mapping(address => bool) public isWhitelistedToken;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event PriceFeedSet(address indexed token, address indexed feed);
    event PoolFeeSet(address indexed tokenA, address indexed tokenB, uint24 fee);
    event SwapPathSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event VaultAuthorized(address indexed vault);
    event VaultDeauthorized(address indexed vault);
    event TokenWhitelisted(address indexed token);
    event TokenDelisted(address indexed token);
    event FactorySet(address indexed factory);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error SameToken();
    error Unauthorized();
    error TokenNotWhitelisted(address token);
    error NoPriceFeed(address token);
    error InvalidPrice(address token);
    error StalePriceFeed(address token);
    error InsufficientOutput(uint256 minRequired, uint256 received);
    error InvalidPath();

    // ─── Modifier ────────────────────────────────────────────────────────────

    modifier onlyVault() {
        if (!authorizedVaults[msg.sender]) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

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
    function setPoolFee(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        _poolFees[_pairHash(tokenA, tokenB)] = fee;
        emit PoolFeeSet(tokenA, tokenB, fee);
    }

    /// @notice Set the VaultFactory address permitted to register new vaults.
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Authorize a vault to call the batch swap functions.
    /// @dev Called by VaultFactory on each createVault(). Owner may also call directly.
    function authorizeVault(address vault_) external {
        if (msg.sender != owner() && msg.sender != factory) revert Unauthorized();
        if (vault_ == address(0)) revert ZeroAddress();
        authorizedVaults[vault_] = true;
        emit VaultAuthorized(vault_);
    }

    /// @notice Remove a vault's swap authorization.
    function deauthorizeVault(address vault_) external onlyOwner {
        authorizedVaults[vault_] = false;
        emit VaultDeauthorized(vault_);
    }

    /// @notice Add a token to the whitelist (accepted for deposit input or withdrawal output).
    function whitelistToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isWhitelistedToken[token] = true;
        emit TokenWhitelisted(token);
    }

    /// @notice Remove a token from the whitelist.
    function delistToken(address token) external onlyOwner {
        isWhitelistedToken[token] = false;
        emit TokenDelisted(token);
    }

    /**
     * @notice Register an ABI-packed Uniswap V3 path for a directed token pair.
     * @dev    Pass empty bytes to clear an existing path and revert to single-hop.
     *         Path format: abi.encodePacked(tokenIn, fee1, hop, fee2, ..., tokenOut)
     *         where each address is 20 bytes and each fee is uint24 (3 bytes).
     *         Minimum valid path: 43 bytes (single hop, stored but will just call exactInput).
     *         Two-hop (e.g. USDT→USDC→WBTC): 66 bytes.
     */
    function setSwapPath(address tokenIn, address tokenOut, bytes calldata path) external onlyOwner {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (path.length != 0) {
            // Valid lengths: 43, 66, 89, ... = 20 + 23*n for n >= 1
            if (path.length < 43 || (path.length - 20) % 23 != 0) revert InvalidPath();
        }
        _swapPaths[_directedHash(tokenIn, tokenOut)] = path;
        emit SwapPathSet(tokenIn, tokenOut, path);
    }

    // ─── Batch swaps (vault only) ─────────────────────────────────────────────

    /**
     * @notice Swap `amountsIn[i]` of `tokenIn` into each `tokensOut[i]`.
     * @dev Caller must approve this contract for sum(amountsIn) of tokenIn.
     *      `tokenIn` must be whitelisted. Each swap is oracle-validated.
     */
    function swapToPortfolio(
        address tokenIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn
    ) external onlyVault returns (uint256[] memory amountsOut) {
        if (!isWhitelistedToken[tokenIn]) revert TokenNotWhitelisted(tokenIn);

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
     *      `tokenOut` must be whitelisted. Returns total tokenOut received.
     */
    function swapToInputToken(
        address[] calldata tokensIn,
        uint256[] calldata amountsIn,
        address tokenOut
    ) external onlyVault returns (uint256 totalOut) {
        if (!isWhitelistedToken[tokenOut]) revert TokenNotWhitelisted(tokenOut);

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

    // ─── Views ────────────────────────────────────────────────────────────────

    function getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        return _getExpectedOutput(tokenIn, tokenOut, amountIn);
    }

    function getMinAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 expected = _getExpectedOutput(tokenIn, tokenOut, amountIn);
        return expected * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS) / BPS_DENOMINATOR;
    }

    function getPoolFee(address tokenA, address tokenB) external view returns (uint24) {
        return _getPoolFee(tokenA, tokenB);
    }

    /// @notice Returns the registered multi-hop path for a directed pair, or empty bytes if none.
    function getSwapPath(address tokenIn, address tokenOut) external view returns (bytes memory) {
        return _swapPaths[_directedHash(tokenIn, tokenOut)];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _executeOracleSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        if (tokenIn == tokenOut) revert SameToken();

        // Oracle validation is end-to-end USD in vs USD out — path routing does not affect it.
        uint256 expected = _getExpectedOutput(tokenIn, tokenOut, amountIn);
        uint256 minOut   = expected * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS) / BPS_DENOMINATOR;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        bytes memory path = _swapPaths[_directedHash(tokenIn, tokenOut)];

        if (path.length > 0) {
            // Multi-hop: use the registered ABI-packed path (e.g. USDT→USDC→WBTC).
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path:             path,
                recipient:        msg.sender,
                deadline:         block.timestamp,
                amountIn:         amountIn,
                amountOutMinimum: minOut
            });
            amountOut = uniswapRouter.exactInput(params);
        } else {
            // Single-hop fallback: direct pool between tokenIn and tokenOut.
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
        }

        if (amountOut < minOut) revert InsufficientOutput(minOut, amountOut);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    function _getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 expectedOut) {
        uint256 priceIn  = _getTokenPrice(tokenIn);
        uint256 priceOut = _getTokenPrice(tokenOut);
        uint8   decIn    = IERC20Metadata(tokenIn).decimals();
        uint8   decOut   = IERC20Metadata(tokenOut).decimals();

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

        if (answer <= 0)                                            revert InvalidPrice(token);
        if (updatedAt == 0 || answeredInRound < roundId)           revert StalePriceFeed(token);
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePriceFeed(token);

        price = uint256(answer);
    }

    function _getPoolFee(address tokenA, address tokenB) internal view returns (uint24 fee) {
        fee = _poolFees[_pairHash(tokenA, tokenB)];
        if (fee == 0) return 3_000;
    }

    function _pairHash(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(a, b));
    }

    // Order-sensitive hash for directional swap paths (tokenIn→tokenOut ≠ tokenOut→tokenIn).
    function _directedHash(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}
