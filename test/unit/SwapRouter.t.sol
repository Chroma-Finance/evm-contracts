// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {SwapRouter} from "../../src/utils/SwapRouter.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

// ─── Mock ERC-20 with configurable decimals ───────────────────────────────────

contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_; symbol = symbol_; decimals = decimals_;
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

// ─── Mock Chainlink aggregator ────────────────────────────────────────────────

contract MockAggregator {
    int256  public price;
    uint256 public updatedAt;
    uint80  public roundId = 1;

    constructor(int256 price_, uint256 updatedAt_) { price = price_; updatedAt = updatedAt_; }

    function setPrice(int256 p) external { price = p; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (roundId, price, 0, updatedAt, roundId);
    }

    function decimals() external pure returns (uint8) { return 8; }
}

// ─── Mock Uniswap V3 SwapRouter ───────────────────────────────────────────────
//
// Returns a configurable ratio of tokenOut per tokenIn. Simulates a fill price.
// The fill ratio is expressed in basis points of the "fair" oracle amount so
// tests can trivially simulate sandwich attacks (ratio < BPS) or normal fills.

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24  fee;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

contract MockUniswapRouter {
    // fillBps: 10000 = fill exactly at oracle price, 9950 = 0.5% slippage, 9900 = 1% slippage
    uint256 public fillBps = 10_000;

    // Minted-to-recipient token amount on the last call (for assertions)
    uint256 public lastAmountOut;

    function setFillBps(uint256 bps) external { fillBps = bps; }

    // Matches the ISwapRouter.ExactInputSingleParams struct layout.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Pull tokenIn from caller (SwapRouter contract)
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Compute fill amount: amountIn * fillBps / 10000
        // (the oracle-expected amount has already been captured in amountOutMinimum by SwapRouter)
        // We use amountOutMinimum as the "oracle fair price" base and scale by fillBps.
        // That way: fillBps=10000 → exact oracle amount, <9950 → slippage exceeds 0.5%.
        amountOut = params.amountOutMinimum * fillBps / 10_000;

        require(amountOut >= params.amountOutMinimum, "MockRouter: slippage");

        // Mint output token to recipient
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
        lastAmountOut = amountOut;
    }
}

// ─── Test suite ───────────────────────────────────────────────────────────────

contract SwapRouterTest is Test {
    SwapRouter        internal router;
    MockUniswapRouter internal mockDex;

    MockERC20 internal usdc; // 6 dec, price $1
    MockERC20 internal wbtc; // 8 dec, price $60 000
    MockERC20 internal weth; // 18 dec, price $3 000

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal user  = makeAddr("user");

    int256 constant USDC_PRICE = 1e8;        // $1.00
    int256 constant WBTC_PRICE = 60_000e8;   // $60 000
    int256 constant WETH_PRICE = 3_000e8;    // $3 000

    function setUp() public {
        mockDex  = new MockUniswapRouter();
        router   = new SwapRouter(address(mockDex));

        usdc = new MockERC20("USD Coin",      "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC",   "WBTC", 8);
        weth = new MockERC20("Wrapped ETH",   "WETH", 18);

        usdcFeed = new MockAggregator(USDC_PRICE, block.timestamp);
        wbtcFeed = new MockAggregator(WBTC_PRICE, block.timestamp);
        wethFeed = new MockAggregator(WETH_PRICE, block.timestamp);

        router.setPriceFeed(address(usdc), address(usdcFeed));
        router.setPriceFeed(address(wbtc), address(wbtcFeed));
        router.setPriceFeed(address(weth), address(wethFeed));

        router.setPoolFee(address(usdc), address(wbtc), 3000);
        router.setPoolFee(address(usdc), address(weth), 500);

        router.setAuthorizedVault(vault);
    }

    // ─── Oracle price logic ───────────────────────────────────────────────────

    function test_getExpectedOutput_usdcToWbtc() public view {
        // 60 000 USDC → 1 WBTC
        uint256 amountIn  = 60_000e6; // 60 000 USDC
        uint256 expected  = router.getExpectedOutput(address(usdc), address(wbtc), amountIn);
        assertEq(expected, 1e8, "60k USDC should yield 1 WBTC");
    }

    function test_getExpectedOutput_usdcToWeth() public view {
        // 3 000 USDC → 1 WETH
        uint256 amountIn = 3_000e6;
        uint256 expected = router.getExpectedOutput(address(usdc), address(weth), amountIn);
        assertEq(expected, 1e18, "3k USDC should yield 1 WETH");
    }

    function test_getExpectedOutput_wbtcToWeth() public view {
        // 1 WBTC ($60k) → 20 WETH ($3k each)
        uint256 amountIn = 1e8;
        uint256 expected = router.getExpectedOutput(address(wbtc), address(weth), amountIn);
        assertEq(expected, 20e18, "1 WBTC should yield 20 WETH");
    }

    function test_getMinAmountOut_appliesSlippage() public view {
        uint256 amountIn = 60_000e6;
        uint256 expected = router.getExpectedOutput(address(usdc), address(wbtc), amountIn);
        uint256 minOut   = router.getMinAmountOut(address(usdc), address(wbtc), amountIn);
        // 0.5% slippage → 99.5% of expected
        assertEq(minOut, expected * 9_950 / 10_000);
    }

    function test_noPriceFeed_reverts() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.NoPriceFeed.selector, unknown));
        router.getExpectedOutput(unknown, address(wbtc), 1e6);
    }

    function test_stalePrice_reverts() public {
        vm.warp(10_000);
        usdcFeed.setUpdatedAt(block.timestamp); // keep USDC fresh so BTC is checked second
        wbtcFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.StalePriceFeed.selector, address(wbtc)));
        router.getExpectedOutput(address(usdc), address(wbtc), 1e6);
    }

    function test_invalidPrice_reverts() public {
        wbtcFeed.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.InvalidPrice.selector, address(wbtc)));
        router.getExpectedOutput(address(usdc), address(wbtc), 1e6);
    }

    // ─── Pool fee lookup ──────────────────────────────────────────────────────

    function test_getPoolFee_configured() public view {
        assertEq(router.getPoolFee(address(usdc), address(wbtc)), 3000);
        assertEq(router.getPoolFee(address(usdc), address(weth)), 500);
    }

    function test_getPoolFee_pairOrderIndependent() public view {
        assertEq(
            router.getPoolFee(address(usdc), address(wbtc)),
            router.getPoolFee(address(wbtc), address(usdc))
        );
    }

    function test_getPoolFee_defaultsTo3000() public view {
        assertEq(router.getPoolFee(address(wbtc), address(weth)), 3000);
    }

    // ─── Access control ───────────────────────────────────────────────────────

    function test_swapToPortfolio_onlyVault() public {
        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = 1e6;

        vm.expectRevert(SwapRouter.Unauthorized.selector);
        vm.prank(user);
        router.swapToPortfolio(address(usdc), tokensOut, amounts);
    }

    function test_swapToInputToken_onlyVault() public {
        address[] memory tokensIn = new address[](1);
        uint256[] memory amounts  = new uint256[](1);
        tokensIn[0] = address(wbtc);
        amounts[0]  = 1e8;

        vm.expectRevert(SwapRouter.Unauthorized.selector);
        vm.prank(user);
        router.swapToInputToken(tokensIn, amounts, address(usdc));
    }

    // ─── Single swap: swapExactInputSingle ───────────────────────────────────

    function test_swapExactInputSingle_happyPath() public {
        uint256 amountIn = 60_000e6;
        uint256 minOut   = 0.99e8; // ~1 WBTC with 1% room
        usdc.mint(user, amountIn);

        vm.startPrank(user);
        usdc.approve(address(router), amountIn);
        uint256 amountOut = router.swapExactInputSingle(
            address(usdc), address(wbtc), 3000, amountIn, minOut
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "should receive WBTC");
        assertEq(usdc.balanceOf(user), 0, "USDC spent");
        assertGt(wbtc.balanceOf(user), 0, "WBTC received");
    }

    function test_swapExactInputSingle_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(SwapRouter.ZeroAmount.selector);
        router.swapExactInputSingle(address(usdc), address(wbtc), 3000, 0, 0);
    }

    // ─── Batch swap: swapToPortfolio ─────────────────────────────────────────

    function test_swapToPortfolio_splitDeposit() public {
        uint256 totalUsdc = 63_000e6; // 60k for WBTC + 3k for WETH
        usdc.mint(vault, totalUsdc);

        address[] memory tokensOut = new address[](2);
        uint256[] memory amounts   = new uint256[](2);
        tokensOut[0] = address(wbtc);  amounts[0] = 60_000e6;
        tokensOut[1] = address(weth);  amounts[1] = 3_000e6;

        vm.startPrank(vault);
        usdc.approve(address(router), totalUsdc);
        uint256[] memory outs = router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();

        assertEq(outs.length, 2);
        assertGt(outs[0], 0, "WBTC out");
        assertGt(outs[1], 0, "WETH out");
        assertEq(wbtc.balanceOf(vault), outs[0], "vault holds WBTC");
        assertEq(weth.balanceOf(vault), outs[1], "vault holds WETH");
    }

    function test_swapToPortfolio_skipsZeroAmounts() public {
        uint256 totalUsdc = 60_000e6;
        usdc.mint(vault, totalUsdc);

        address[] memory tokensOut = new address[](2);
        uint256[] memory amounts   = new uint256[](2);
        tokensOut[0] = address(wbtc);  amounts[0] = totalUsdc;
        tokensOut[1] = address(weth);  amounts[1] = 0; // skip

        vm.startPrank(vault);
        usdc.approve(address(router), totalUsdc);
        uint256[] memory outs = router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();

        assertGt(outs[0], 0);
        assertEq(outs[1], 0, "skipped zero-amount swap");
        assertEq(weth.balanceOf(vault), 0, "no WETH minted");
    }

    // ─── Batch swap: swapToInputToken ────────────────────────────────────────

    function test_swapToInputToken_batchWithdrawal() public {
        uint256 wbtcAmount = 1e8;   // 1 WBTC
        uint256 wethAmount = 10e18; // 10 WETH
        wbtc.mint(vault, wbtcAmount);
        weth.mint(vault, wethAmount);

        address[] memory tokensIn = new address[](2);
        uint256[] memory amounts  = new uint256[](2);
        tokensIn[0] = address(wbtc);  amounts[0] = wbtcAmount;
        tokensIn[1] = address(weth);  amounts[1] = wethAmount;

        vm.startPrank(vault);
        wbtc.approve(address(router), wbtcAmount);
        weth.approve(address(router), wethAmount);
        uint256 totalUsdc = router.swapToInputToken(tokensIn, amounts, address(usdc));
        vm.stopPrank();

        assertGt(totalUsdc, 0, "received USDC");
        assertEq(usdc.balanceOf(vault), totalUsdc, "vault holds USDC");
    }

    // ─── Oracle slippage protection ───────────────────────────────────────────

    function test_swapToPortfolio_oracleBlocksSandwich() public {
        // Set DEX fill to 98% — exceeds 0.5% max slippage → must revert
        mockDex.setFillBps(9_800);

        uint256 amountIn = 60_000e6;
        usdc.mint(vault, amountIn);

        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = amountIn;

        vm.startPrank(vault);
        usdc.approve(address(router), amountIn);
        vm.expectRevert("MockRouter: slippage");
        router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();
    }

    function test_swapToPortfolio_acceptsExactMinSlippage() public {
        // Fill at exactly minAmountOut (0.5% below oracle) → should succeed
        // MockRouter: fillBps=10000 fills at exactly minAmountOut (which IS 99.5%)
        mockDex.setFillBps(10_000); // exact fill of minAmountOut

        uint256 amountIn = 60_000e6;
        usdc.mint(vault, amountIn);

        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = amountIn;

        vm.startPrank(vault);
        usdc.approve(address(router), amountIn);
        uint256[] memory outs = router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();

        assertGt(outs[0], 0);
    }

    // ─── Same-token check ─────────────────────────────────────────────────────

    function test_swapToPortfolio_sameToken_reverts() public {
        usdc.mint(vault, 1e6);

        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(usdc); // same as tokenIn
        amounts[0]   = 1e6;

        vm.startPrank(vault);
        usdc.approve(address(router), 1e6);
        vm.expectRevert(SwapRouter.SameToken.selector);
        router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();
    }
}

// ─── Integration: PortfolioVault deposit/withdraw with SwapRouter ─────────────

contract VaultSwapIntegrationTest is Test {
    SwapRouter        internal router;
    MockUniswapRouter internal mockDex;
    PortfolioVault    internal vault;
    VaultFactory      internal factory;
    RiskTierRegistry  internal registry;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    address internal owner        = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice        = makeAddr("alice");

    int256 constant USDC_PRICE = 1e8;
    int256 constant WBTC_PRICE = 60_000e8;
    int256 constant WETH_PRICE = 3_000e8;

    function setUp() public {
        // Tokens
        usdc = new MockERC20("USD Coin",    "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);

        // Oracle feeds
        usdcFeed = new MockAggregator(USDC_PRICE, block.timestamp);
        wbtcFeed = new MockAggregator(WBTC_PRICE, block.timestamp);
        wethFeed = new MockAggregator(WETH_PRICE, block.timestamp);

        // Dex + router
        mockDex = new MockUniswapRouter();
        router  = new SwapRouter(address(mockDex));

        router.setPriceFeed(address(usdc), address(usdcFeed));
        router.setPriceFeed(address(wbtc), address(wbtcFeed));
        router.setPriceFeed(address(weth), address(wethFeed));
        router.setPoolFee(address(usdc), address(wbtc), 3000);
        router.setPoolFee(address(usdc), address(weth), 500);
        router.setPoolFee(address(wbtc), address(weth), 3000);

        // Registry + factory
        registry = new RiskTierRegistry();

        address[] memory assets  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        assets[0] = address(wbtc);  weights[0] = 5_000;  feeds[0] = address(wbtcFeed);
        assets[1] = address(weth);  weights[1] = 5_000;  feeds[1] = address(wethFeed);
        registry.createTier(0, "Test Tier", assets, weights, feeds);

        factory = new VaultFactory(address(usdc), address(registry), feeRecipient);

        vm.prank(owner);
        address vaultAddr = factory.createVault(0, false);
        vault = PortfolioVault(vaultAddr);

        // Wire swap router
        vm.prank(owner);
        vault.setSwapRouter(address(router));
        router.setAuthorizedVault(address(vault));
    }

    // ─── Deposit flow ─────────────────────────────────────────────────────────

    function test_deposit_swapsUsdcIntoPortfolio() public {
        uint256 depositAmount = 63_000e6; // 63k USDC
        usdc.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertGt(wbtc.balanceOf(address(vault)), 0, "vault holds WBTC");
        assertGt(weth.balanceOf(address(vault)), 0, "vault holds WETH");
        assertEq(usdc.balanceOf(address(vault)), 0, "no USDC left in vault");
    }

    function test_deposit_mintsSharesProportionally() public {
        uint256 deposit1 = 60_000e6;
        uint256 deposit2 = 60_000e6;

        // First depositor
        usdc.mint(alice, deposit1);
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit1);
        uint256 shares1 = vault.deposit(deposit1, alice);
        vm.stopPrank();

        // Second depositor (same amount, same prices)
        address bob = makeAddr("bob");
        usdc.mint(bob, deposit2);
        vm.startPrank(bob);
        usdc.approve(address(vault), deposit2);
        uint256 shares2 = vault.deposit(deposit2, bob);
        vm.stopPrank();

        // Both should receive approximately equal shares
        assertApproxEqRel(shares1, shares2, 0.01e18, "shares should be proportional");
    }

    // ─── Withdraw flow ────────────────────────────────────────────────────────

    function test_withdraw_convertsPortfolioToUsdc() public {
        // Deposit with swap enabled so vault holds portfolio tokens
        uint256 depositAmount = 63_000e6;
        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertGt(vault.balanceOf(alice), 0, "alice has shares");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no USDC");
        assertGt(wbtc.balanceOf(address(vault)), 0, "vault holds WBTC");
        assertGt(weth.balanceOf(address(vault)), 0, "vault holds WETH");

        // withdrawAll converts portfolio back to USDC
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawAll();

        assertGt(usdc.balanceOf(alice) - usdcBefore, 0, "alice received USDC");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
    }

    // ─── No swap router: backward compatibility ───────────────────────────────

    function test_deposit_noRouter_holdsUsdc() public {
        vm.prank(owner);
        vault.setSwapRouter(address(0));

        uint256 depositAmount = 1_000e6;
        usdc.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), depositAmount, "vault holds USDC when no router");
    }

    // ─── SwapRouter access control via vault ─────────────────────────────────

    function test_routerRejects_directCallerNotVault() public {
        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = 1_000e6;

        vm.prank(alice);
        vm.expectRevert(SwapRouter.Unauthorized.selector);
        router.swapToPortfolio(address(usdc), tokensOut, amounts);
    }
}
