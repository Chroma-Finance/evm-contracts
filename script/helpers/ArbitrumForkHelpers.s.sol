// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script}       from "forge-std/Script.sol";
import {StdCheats}    from "forge-std/StdCheats.sol";
import {console}      from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool}    from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IQuoter}           from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {PortfolioVault}    from "../../src/core/PortfolioVault.sol";

/**
 * @title ArbitrumForkHelpers
 * @notice Utility functions for debugging and inspecting protocol state in fork tests.
 *
 *         All Uniswap/Quoter addresses default to Arbitrum One mainnet.
 *
 *         Usage (in a fork test):
 *           ArbitrumForkHelpers helpers = new ArbitrumForkHelpers();
 *           helpers.dealTokens(user, usdc, usdt, dai, 1_000e6, 500e6, 200e18);
 *           helpers.printVaultState(vault);
 */
contract ArbitrumForkHelpers is Script, StdCheats {

    // ─── Arbitrum One constants ───────────────────────────────────────────────

    address public constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNISWAP_QUOTER     = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

    // ─── dealTokens ───────────────────────────────────────────────────────────

    /**
     * @notice Give `user` a balance of USDC, USDT, and DAI via Foundry's deal() cheatcode.
     *
     * @param user       Recipient address.
     * @param usdc       USDC address on the fork chain.
     * @param usdt       USDT address on the fork chain.
     * @param dai        DAI address on the fork chain.
     * @param usdcAmount Raw USDC amount (6 decimals — e.g. 1_000e6 for $1,000).
     * @param usdtAmount Raw USDT amount (6 decimals).
     * @param daiAmount  Raw DAI  amount (18 decimals — e.g. 500e18 for $500).
     */
    function dealTokens(
        address user,
        address usdc,
        address usdt,
        address dai,
        uint256 usdcAmount,
        uint256 usdtAmount,
        uint256 daiAmount
    ) public {
        require(user != address(0), "dealTokens: zero user");

        if (usdcAmount > 0) {
            require(usdc != address(0), "dealTokens: zero USDC");
            deal(usdc, user, usdcAmount);
            console.log("[deal] USDC ->", user);
            console.log("       amount:", usdcAmount);
        }
        if (usdtAmount > 0) {
            require(usdt != address(0), "dealTokens: zero USDT");
            deal(usdt, user, usdtAmount);
            console.log("[deal] USDT ->", user);
            console.log("       amount:", usdtAmount);
        }
        if (daiAmount > 0) {
            require(dai != address(0), "dealTokens: zero DAI");
            deal(dai, user, daiAmount);
            console.log("[deal] DAI  ->", user);
            console.log("       amount:", daiAmount);
        }
    }

    // ─── getTokenInfo ─────────────────────────────────────────────────────────

    /**
     * @notice Returns ERC-20 metadata and the token balance of `holder`.
     *
     * @param token  ERC-20 token address.
     * @param holder Address whose balance to query.
     * @return symbol_   Token symbol string.
     * @return decimals_ Token decimal count.
     * @return balance   Raw balance of `holder`.
     */
    function getTokenInfo(address token, address holder)
        public view
        returns (string memory symbol_, uint8 decimals_, uint256 balance)
    {
        require(token != address(0),   "getTokenInfo: zero token");
        require(token.code.length > 0, "getTokenInfo: not a contract");

        IERC20Metadata erc20 = IERC20Metadata(token);
        symbol_   = erc20.symbol();
        decimals_ = erc20.decimals();
        balance   = erc20.balanceOf(holder);
    }

    /**
     * @notice Logs ERC-20 metadata and `holder` balance to the console.
     */
    function logTokenInfo(address token, address holder) public view {
        (string memory sym, uint8 dec, uint256 bal) = getTokenInfo(token, holder);
        console.log("[token] symbol:", sym);
        console.log("        decimals:", uint256(dec));
        console.log("        balance:", bal);
    }

    // ─── getPriceFromFeed ─────────────────────────────────────────────────────

    /**
     * @notice Fetches the latest price and update timestamp from a Chainlink aggregator.
     *
     * @param feed       Chainlink AggregatorV3Interface address.
     * @return price     Latest answer cast to uint256 (feed-native decimals).
     * @return updatedAt Unix timestamp of the most recent update.
     */
    function getPriceFromFeed(address feed)
        public view
        returns (uint256 price, uint256 updatedAt)
    {
        require(feed != address(0),   "getPriceFromFeed: zero feed");
        require(feed.code.length > 0, "getPriceFromFeed: not a contract");

        (
            uint80  roundId,
            int256  answer,
            ,
            uint256 updatedAt_,
            uint80  answeredInRound
        ) = AggregatorV3Interface(feed).latestRoundData();

        require(answer > 0,                "getPriceFromFeed: non-positive price");
        require(updatedAt_ > 0,            "getPriceFromFeed: updatedAt is zero");
        require(answeredInRound >= roundId, "getPriceFromFeed: stale round");

        price     = uint256(answer);
        updatedAt = updatedAt_;
    }

    /**
     * @notice Logs the latest price from `feed` together with its age in seconds.
     */
    function logPriceFromFeed(address feed) public view {
        (uint256 price, uint256 updatedAt) = getPriceFromFeed(feed);
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        console.log("[feed]", feed);
        console.log("       price:", price);
        console.log("       age (s):", age);
    }

    // ─── simulateUniswapSwap ──────────────────────────────────────────────────

    /**
     * @notice Simulates a single-hop Uniswap V3 swap via the on-chain Quoter.
     *
     * @dev Probes fee tiers [100, 500, 3000, 10000] and uses the first pool found.
     *      Falls back to 3000 if none match (Quoter will revert if pool is truly missing).
     *      The Quoter is non-view so this is only valid inside a fork test or script.
     *
     * @param tokenIn   Input token address.
     * @param tokenOut  Output token address.
     * @param amountIn  Exact amount of `tokenIn` to swap.
     * @return amountOut Expected output amount from the Quoter.
     */
    function simulateUniswapSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public returns (uint256 amountOut) {
        require(tokenIn  != address(0), "simulateUniswapSwap: zero tokenIn");
        require(tokenOut != address(0), "simulateUniswapSwap: zero tokenOut");
        require(tokenIn  != tokenOut,   "simulateUniswapSwap: same token");
        require(amountIn > 0,           "simulateUniswapSwap: zero amountIn");

        uint24[4] memory feeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);

        uint24 fee;
        for (uint256 i = 0; i < feeTiers.length; i++) {
            if (factory.getPool(tokenIn, tokenOut, feeTiers[i]) != address(0)) {
                fee = feeTiers[i];
                break;
            }
        }
        if (fee == 0) fee = 3000;

        amountOut = IQuoter(UNISWAP_QUOTER).quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);

        console.log("[quote] tokenIn:", tokenIn);
        console.log("        tokenOut:", tokenOut);
        console.log("        amountIn:", amountIn);
        console.log("        amountOut:", amountOut);
        console.log("        fee:", uint256(fee));
    }

    // ─── printVaultState ──────────────────────────────────────────────────────

    /**
     * @notice Logs a complete snapshot of vault state for debugging.
     *
     *         Prints:
     *           - Owner address and risk tier
     *           - Total shares (supply) and total assets (USD, 8 decimals)
     *           - Per-asset: balance and USD value
     *           - Share price (USD per share, scaled by 1e8)
     *
     * @param vault PortfolioVault proxy address.
     */
    function printVaultState(address vault) public view {
        require(vault != address(0),   "printVaultState: zero vault");
        require(vault.code.length > 0, "printVaultState: not a contract");

        PortfolioVault pv = PortfolioVault(vault);

        uint256 totalSupply = pv.totalSupply();
        uint256 totalAssets = pv.totalAssets();

        console.log("=== Vault State ===");
        console.log("  vault        :", vault);
        console.log("  owner        :", pv.vaultOwner());
        console.log("  risk tier    :", uint256(pv.riskTier()));
        console.log("  total supply :", totalSupply);
        console.log("  total assets :", totalAssets);

        uint256 n = _portfolioLength(pv);
        for (uint256 i = 0; i < n; i++) {
            (address token, uint256 weight) = _portfolioAsset(pv, i);
            if (token == address(0)) continue;

            string  memory sym = _trySymbol(token);
            uint8   dec        = _tryDecimals(token);
            uint256 balance    = IERC20Metadata(token).balanceOf(vault);

            uint256 usdVal = 0;
            try pv.getTokenPrice(token) returns (uint256 price) {
                usdVal = balance * price / (10 ** uint256(dec));
            } catch {}

            console.log("  [asset]", sym);
            console.log("    weight bps:", weight);
            console.log("    balance:", balance);
            console.log("    usd value:", usdVal);
        }

        uint256 sharePrice = totalSupply > 0 ? (totalAssets * 1e8) / totalSupply : 0;
        console.log("  share price  :", sharePrice);
        console.log("=== End Vault State ===");
    }

    // ─── checkPoolLiquidity ───────────────────────────────────────────────────

    /**
     * @notice Checks whether a Uniswap V3 pool exists for `tokenA`/`tokenB` at any
     *         standard fee tier and returns its current in-range liquidity.
     *
     * @dev Iterates fee tiers [100, 500, 3000, 10000] and returns the first pool found.
     *      `liquidity` is the pool's `liquidity()` slot (active tick liquidity only).
     *
     * @param tokenA One token of the pair.
     * @param tokenB Other token of the pair.
     * @return exists    True if at least one pool was found.
     * @return liquidity In-range liquidity of the first found pool (0 if none found).
     */
    function checkPoolLiquidity(address tokenA, address tokenB)
        public view
        returns (bool exists, uint256 liquidity)
    {
        require(tokenA != address(0), "checkPoolLiquidity: zero tokenA");
        require(tokenB != address(0), "checkPoolLiquidity: zero tokenB");
        require(tokenA != tokenB,     "checkPoolLiquidity: same token");

        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        uint24[4] memory feeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(tokenA, tokenB, feeTiers[i]);
            if (pool != address(0)) {
                exists    = true;
                liquidity = uint256(IUniswapV3Pool(pool).liquidity());
                console.log("[pool] tokenA:", tokenA);
                console.log("       tokenB:", tokenB);
                console.log("       fee:", uint256(feeTiers[i]));
                console.log("       liquidity:", liquidity);
                return (exists, liquidity);
            }
        }

        console.log("[pool] NO POOL FOUND for pair");
        console.log("       tokenA:", tokenA);
        console.log("       tokenB:", tokenB);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _portfolioLength(PortfolioVault pv) internal view returns (uint256 n) {
        while (true) {
            try pv.portfolio(n) returns (address, uint256) {
                unchecked { n++; }
            } catch {
                break;
            }
        }
    }

    function _portfolioAsset(PortfolioVault pv, uint256 i)
        internal view
        returns (address token, uint256 weight)
    {
        try pv.portfolio(i) returns (address t, uint256 w) {
            token  = t;
            weight = w;
        } catch {}
    }

    function _trySymbol(address token) internal view returns (string memory sym) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            sym = s;
        } catch {
            sym = "???";
        }
    }

    function _tryDecimals(address token) internal view returns (uint8 dec) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            dec = 18;
        }
    }
}
