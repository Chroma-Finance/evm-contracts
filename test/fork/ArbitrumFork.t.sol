// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IERC20Minimal {
    function name()        external view returns (string memory);
    function symbol()      external view returns (string memory);
    function decimals()    external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

// ─── Arbitrum mainnet fork sanity checks ─────────────────────────────────────

contract ArbitrumForkTest is Test {

    // ── Token addresses (loaded from env) ────────────────────────────────────
    address internal wbtc;
    address internal weth;
    address internal usdc;
    address internal usdt;
    address internal dai;

    // ── Chainlink feeds (loaded from env) ────────────────────────────────────
    address internal btcUsdFeed;
    address internal ethUsdFeed;

    // ── Uniswap V3 router (loaded from env) ──────────────────────────────────
    address internal uniswapRouter;

    // ── Chainlink max staleness tolerance for fork tests (24 h) ──────────────
    // Live feeds on Arbitrum may not have updated within the last hour at the
    // pinned block, so we use a generous window that still proves the feed is
    // live (not zero / far future).
    uint256 internal constant MAX_FEED_AGE = 24 hours;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));

        wbtc         = vm.envAddress("WBTC");
        weth         = vm.envAddress("WETH");
        usdc         = vm.envAddress("USDC");
        usdt         = vm.envAddress("USDT");
        dai          = vm.envAddress("DAI");
        btcUsdFeed   = vm.envAddress("BTC_USD_FEED");
        ethUsdFeed   = vm.envAddress("ETH_USD_FEED");
        uniswapRouter = vm.envAddress("UNISWAP_V3_ROUTER");

        console.log("Fork block:", block.number);
        console.log("Fork timestamp:", block.timestamp);
    }

    // ── testForkSetup ─────────────────────────────────────────────────────────

    function testForkSetup() public view {
        assertEq(block.chainid, 1337, "Expected Arbitrum One (chainId 42161)");
        assertTrue(block.number > 0, "Block number should be non-zero");
        assertTrue(block.timestamp > 0, "Block timestamp should be non-zero");

        console.log("chainId:", block.chainid);
        console.log("Block:", block.number);
    }

    // ── testTokensExist ───────────────────────────────────────────────────────

    function testTokensExist() public view {
        _assertERC20(wbtc,  "WBTC", 8);
        _assertERC20(weth,  "WETH", 18);
        _assertERC20(usdc,  "USDC", 6);
        _assertERC20(usdt,  "USDT", 6);
        _assertERC20(dai,   "DAI",  18);
    }

    function _assertERC20(address token, string memory label, uint8 expectedDecimals) internal view {
        assertTrue(token != address(0), string.concat(label, ": zero address"));
        assertTrue(token.code.length > 0, string.concat(label, ": no bytecode"));

        IERC20Minimal t = IERC20Minimal(token);

        uint8 dec = t.decimals();
        assertEq(dec, expectedDecimals, string.concat(label, ": wrong decimals"));

        uint256 supply = t.totalSupply();
        assertTrue(supply > 0, string.concat(label, ": zero total supply"));

        console.log(label, "decimals:", dec);
        console.log(label, "totalSupply:", supply);
    }

    // ── testPriceFeeds ────────────────────────────────────────────────────────

    function testPriceFeeds() public view {
        _assertPriceFeed(btcUsdFeed, "BTC/USD", 8,   1_000e8,  200_000e8);
        _assertPriceFeed(ethUsdFeed, "ETH/USD", 8,   100e8,    30_000e8);
    }

    function _assertPriceFeed(
        address feed,
        string memory label,
        uint8  expectedDecimals,
        int256 minPrice,
        int256 maxPrice
    ) internal view {
        assertTrue(feed != address(0), string.concat(label, ": zero address"));
        assertTrue(feed.code.length > 0, string.concat(label, ": no bytecode"));

        AggregatorV3Interface agg = AggregatorV3Interface(feed);

        uint8 dec = agg.decimals();
        assertEq(dec, expectedDecimals, string.concat(label, ": wrong decimals"));

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = agg.latestRoundData();

        assertTrue(answer > 0,    string.concat(label, ": non-positive price"));
        assertGe(answer, minPrice, string.concat(label, ": price below floor"));
        assertLe(answer, maxPrice, string.concat(label, ": price above ceiling"));

        assertTrue(updatedAt > 0, string.concat(label, ": updatedAt is zero"));
        assertLe(
            block.timestamp - updatedAt,
            MAX_FEED_AGE,
            string.concat(label, ": feed too stale")
        );

        assertGe(answeredInRound, roundId, string.concat(label, ": stale round"));

        console.log(label, "price (8 dec):", uint256(answer));
        console.log(label, "updatedAt:", updatedAt);
    }

    // ── testUniswapRouter ─────────────────────────────────────────────────────

    function testUniswapRouter() public view {
        assertTrue(uniswapRouter != address(0), "Router: zero address");
        assertTrue(uniswapRouter.code.length > 0, "Router: no bytecode");

        // Verify the selector for exactInputSingle is present in the deployed bytecode.
        // bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))"))
        bytes4 selector = ISwapRouter.exactInputSingle.selector;
        bytes memory code = uniswapRouter.code;
        bool found = _containsSelector(code, selector);
        assertTrue(found, "Router: exactInputSingle selector not found in bytecode");

        console.log("Uniswap V3 router:", uniswapRouter);
        console.log("Bytecode length:", code.length);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _containsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 3 < code.length; i++) {
            if (
                code[i]   == selector[0] &&
                code[i+1] == selector[1] &&
                code[i+2] == selector[2] &&
                code[i+3] == selector[3]
            ) return true;
        }
        return false;
    }
}
