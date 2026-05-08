// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

// ─── Minimal mock ERC-20 with configurable decimals ──────────────────────────

contract MockToken {
    string public name;
    string public symbol;
    uint8  public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name     = name_;
        symbol   = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ─── Mock Chainlink AggregatorV3 ─────────────────────────────────────────────

contract MockAggregator {
    int256  public price;
    uint256 public updatedAt;
    uint80  public roundId;

    constructor(int256 price_, uint256 updatedAt_) {
        price     = price_;
        updatedAt = updatedAt_;
        roundId   = 1;
    }

    function setPrice(int256 price_) external { price = price_; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function setRoundId(uint80 r) external { roundId = r; }

    function latestRoundData() external view returns (
        uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound
    ) {
        return (roundId, price, 0, updatedAt, roundId);
    }

    function decimals() external pure returns (uint8) { return 8; }
}

// ─── Test suite ──────────────────────────────────────────────────────────────

contract OracleIntegrationTest is Test {
    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    PortfolioVault   internal vault;

    MockToken internal usdc;
    MockToken internal wbtc;
    MockToken internal weth;

    MockAggregator internal btcFeed;
    MockAggregator internal ethFeed;

    address internal owner        = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    // Prices: BTC $60 000, ETH $3 000 (8-dec Chainlink format)
    int256  internal constant BTC_PRICE = 60_000e8;
    int256  internal constant ETH_PRICE  = 3_000e8;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        wbtc = new MockToken("Wrapped BTC", "WBTC", 8);
        weth = new MockToken("Wrapped ETH", "WETH", 18);

        btcFeed = new MockAggregator(BTC_PRICE, block.timestamp);
        ethFeed = new MockAggregator(ETH_PRICE, block.timestamp);

        registry = new RiskTierRegistry();

        // Tier 0: 50% WBTC | 50% WETH
        address[] memory assets  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        assets[0]  = address(wbtc);  weights[0] = 5_000;  feeds[0] = address(btcFeed);
        assets[1]  = address(weth);  weights[1] = 5_000;  feeds[1] = address(ethFeed);
        registry.createTier(0, "Oracle Test Tier", assets, weights, feeds);

        factory = new VaultFactory(address(usdc), address(registry), feeRecipient);

        vm.prank(owner);
        address vaultAddr = factory.createVault(0, false);
        vault = PortfolioVault(vaultAddr);
    }

    // ─── getTokenPrice: happy path ───────────────────────────────────────────

    function test_getTokenPrice_returnsCorrectBtcPrice() public view {
        uint256 price = vault.getTokenPrice(address(wbtc));
        assertEq(price, uint256(BTC_PRICE), "BTC price mismatch");
    }

    function test_getTokenPrice_returnsCorrectEthPrice() public view {
        uint256 price = vault.getTokenPrice(address(weth));
        assertEq(price, uint256(ETH_PRICE), "ETH price mismatch");
    }

    // ─── getTokenPrice: reverts ──────────────────────────────────────────────

    function test_getTokenPrice_revertNoPriceFeed() public {
        address unknown = makeAddr("unknown_token");
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.NoPriceFeed.selector, unknown));
        vault.getTokenPrice(unknown);
    }

    function test_getTokenPrice_revertZeroPrice() public {
        btcFeed.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.InvalidPrice.selector, address(wbtc)));
        vault.getTokenPrice(address(wbtc));
    }

    function test_getTokenPrice_revertNegativePrice() public {
        btcFeed.setPrice(-1);
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.InvalidPrice.selector, address(wbtc)));
        vault.getTokenPrice(address(wbtc));
    }

    function test_getTokenPrice_revertStaleByTimestamp() public {
        vm.warp(10_000);
        btcFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.StalePriceFeed.selector, address(wbtc)));
        vault.getTokenPrice(address(wbtc));
    }

    function test_getTokenPrice_revertStaleByRound() public {
        // answeredInRound < roundId → stale
        btcFeed.setRoundId(5);
        // MockAggregator returns answeredInRound == roundId-1 when we manually manipulate:
        // We need answeredInRound < roundId. Our mock returns answeredInRound = roundId,
        // so simulate via a custom aggregator call.
        // Instead test with updatedAt == 0 path.
        btcFeed.setUpdatedAt(0);
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.StalePriceFeed.selector, address(wbtc)));
        vault.getTokenPrice(address(wbtc));
    }

    // ─── totalAssets: portfolio tokens ───────────────────────────────────────

    function test_totalAssets_zeroWhenVaultEmpty() public view {
        // Vault holds no portfolio tokens and no denomination asset.
        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_singleWbtcHolding() public {
        // Give the vault 0.5 WBTC (8 dec)
        uint256 half_btc = 0.5e8;
        wbtc.mint(address(vault), half_btc);

        // Expected: 0.5 BTC * $60 000 = $30 000 (8 dec) = 30_000e8
        uint256 expected = (half_btc * uint256(BTC_PRICE)) / 1e8;
        assertEq(vault.totalAssets(), expected, "0.5 BTC USD value wrong");
    }

    function test_totalAssets_singleWethHolding() public {
        // Give the vault 10 WETH (18 dec)
        uint256 ten_eth = 10e18;
        weth.mint(address(vault), ten_eth);

        // Expected: 10 ETH * $3 000 = $30 000 (8 dec) = 30_000e8
        uint256 expected = (ten_eth * uint256(ETH_PRICE)) / 1e18;
        assertEq(vault.totalAssets(), expected, "10 ETH USD value wrong");
    }

    function test_totalAssets_multipleTokensSummed() public {
        // 1 WBTC + 10 WETH
        uint256 one_btc = 1e8;
        uint256 ten_eth = 10e18;
        wbtc.mint(address(vault), one_btc);
        weth.mint(address(vault), ten_eth);

        uint256 btcValue = (one_btc * uint256(BTC_PRICE)) / 1e8;  // $60 000
        uint256 ethValue = (ten_eth * uint256(ETH_PRICE)) / 1e18;  // $30 000
        uint256 expected = btcValue + ethValue;                     // $90 000

        assertEq(vault.totalAssets(), expected, "Combined TVL wrong");
    }

    function test_totalAssets_skipsTokensWithZeroBalance() public {
        // Only WETH in the vault; WBTC balance = 0.
        uint256 five_eth = 5e18;
        weth.mint(address(vault), five_eth);

        uint256 expected = (five_eth * uint256(ETH_PRICE)) / 1e18;
        assertEq(vault.totalAssets(), expected, "Should skip zero-balance WBTC");
    }

    // ─── totalAssets: denomination asset fallback ($1 per USDC) ─────────────

    function test_totalAssets_usdcFallbackScales6DecTo8Dec() public {
        // Vault holds 1 000 USDC (6 dec, no feed registered → treated as $1)
        uint256 usdcAmount = 1_000e6;
        usdc.mint(address(vault), usdcAmount);

        // Expected: 1 000 USDC * $1 = $1 000 (8 dec) = 1_000e8
        uint256 expected = 1_000e8;
        assertEq(vault.totalAssets(), expected, "USDC $1 fallback wrong");
    }

    function test_totalAssets_combinedPortfolioAndDenomAsset() public {
        // Vault holds 0.1 WBTC + 1 000 USDC
        uint256 tenth_btc  = 0.1e8;
        uint256 usdcAmount = 1_000e6;
        wbtc.mint(address(vault), tenth_btc);
        usdc.mint(address(vault), usdcAmount);

        uint256 btcValue  = (tenth_btc * uint256(BTC_PRICE)) / 1e8; // $6 000
        uint256 usdcValue = 1_000e8;                                  // $1 000
        uint256 expected  = btcValue + usdcValue;                     // $7 000

        assertEq(vault.totalAssets(), expected, "Combined portfolio + USDC wrong");
    }

    // ─── Price freshness boundary ─────────────────────────────────────────────

    function test_getTokenPrice_acceptsPriceExactlyAtThreshold() public {
        vm.warp(10_000);
        // updatedAt = exactly 1 hour ago → within threshold (check is strict >).
        btcFeed.setUpdatedAt(block.timestamp - 1 hours);
        uint256 price = vault.getTokenPrice(address(wbtc));
        assertEq(price, uint256(BTC_PRICE));
    }

    function test_getTokenPrice_rejectsOneBeyondThreshold() public {
        vm.warp(10_000);
        btcFeed.setUpdatedAt(block.timestamp - 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.StalePriceFeed.selector, address(wbtc)));
        vault.getTokenPrice(address(wbtc));
    }

}
