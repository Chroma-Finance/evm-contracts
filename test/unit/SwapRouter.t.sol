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

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, 0, updatedAt, roundId);
    }

    function decimals() external pure returns (uint8) { return 8; }
}

// ─── Mock Uniswap V3 SwapRouter ───────────────────────────────────────────────
//
// Returns a configurable ratio of tokenOut per tokenIn. fillBps=10000 = oracle price,
// 9950 = 0.5% slippage, 9800 = 2% slippage (exceeds MAX_SLIPPAGE_BPS).

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
    uint256 public fillBps = 10_000;
    uint256 public lastAmountOut;

    function setFillBps(uint256 bps) external { fillBps = bps; }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external returns (uint256 amountOut)
    {
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountOutMinimum * fillBps / 10_000;
        require(amountOut >= params.amountOutMinimum, "MockRouter: slippage");
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
        lastAmountOut = amountOut;
    }
}

// ─── SwapRouter unit tests ────────────────────────────────────────────────────

contract SwapRouterTest is Test {
    SwapRouter        internal router;
    MockUniswapRouter internal mockDex;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal user  = makeAddr("user");

    int256 constant USDC_PRICE = 1e8;
    int256 constant WBTC_PRICE = 60_000e8;
    int256 constant WETH_PRICE = 3_000e8;

    function setUp() public {
        mockDex = new MockUniswapRouter();
        router  = new SwapRouter(address(mockDex));

        usdc = new MockERC20("USD Coin",    "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);

        usdcFeed = new MockAggregator(USDC_PRICE, block.timestamp);
        wbtcFeed = new MockAggregator(WBTC_PRICE, block.timestamp);
        wethFeed = new MockAggregator(WETH_PRICE, block.timestamp);

        router.setPriceFeed(address(usdc), address(usdcFeed));
        router.setPriceFeed(address(wbtc), address(wbtcFeed));
        router.setPriceFeed(address(weth), address(wethFeed));

        router.setPoolFee(address(usdc), address(wbtc), 3000);
        router.setPoolFee(address(usdc), address(weth), 500);

        // Authorize the mock vault address and whitelist USDC as a deposit/withdrawal token.
        router.authorizeVault(vault);
        router.whitelistToken(address(usdc));
    }

    // ─── Oracle price logic ───────────────────────────────────────────────────

    function test_getExpectedOutput_usdcToWbtc() public view {
        uint256 amountIn = 60_000e6;
        uint256 expected = router.getExpectedOutput(address(usdc), address(wbtc), amountIn);
        assertEq(expected, 1e8, "60k USDC should yield 1 WBTC");
    }

    function test_getExpectedOutput_usdcToWeth() public view {
        uint256 amountIn = 3_000e6;
        uint256 expected = router.getExpectedOutput(address(usdc), address(weth), amountIn);
        assertEq(expected, 1e18, "3k USDC should yield 1 WETH");
    }

    function test_getExpectedOutput_wbtcToWeth() public view {
        uint256 amountIn = 1e8;
        uint256 expected = router.getExpectedOutput(address(wbtc), address(weth), amountIn);
        assertEq(expected, 20e18, "1 WBTC should yield 20 WETH");
    }

    function test_getMinAmountOut_appliesSlippage() public view {
        uint256 amountIn = 60_000e6;
        uint256 expected = router.getExpectedOutput(address(usdc), address(wbtc), amountIn);
        uint256 minOut   = router.getMinAmountOut(address(usdc), address(wbtc), amountIn);
        assertEq(minOut, expected * 9_500 / 10_000);
    }

    function test_noPriceFeed_reverts() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.NoPriceFeed.selector, unknown));
        router.getExpectedOutput(unknown, address(wbtc), 1e6);
    }

    function test_stalePrice_reverts() public {
        vm.warp(10_000);
        usdcFeed.setUpdatedAt(block.timestamp);
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

    // ─── Token whitelist ──────────────────────────────────────────────────────

    function test_swapToPortfolio_unlistedToken_reverts() public {
        address unlisted = makeAddr("unknown");
        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = 1e6;

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.TokenNotWhitelisted.selector, unlisted));
        router.swapToPortfolio(unlisted, tokensOut, amounts);
    }

    function test_swapToInputToken_unlistedToken_reverts() public {
        address unlisted = makeAddr("unknown");
        address[] memory tokensIn = new address[](1);
        uint256[] memory amounts  = new uint256[](1);
        tokensIn[0] = address(wbtc);
        amounts[0]  = 1e8;

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.TokenNotWhitelisted.selector, unlisted));
        router.swapToInputToken(tokensIn, amounts, unlisted);
    }

    // ─── Single swap: swapExactInputSingle ───────────────────────────────────

    function test_swapExactInputSingle_happyPath() public {
        uint256 amountIn = 60_000e6;
        uint256 minOut   = 0.99e8;
        usdc.mint(user, amountIn);

        vm.startPrank(user);
        usdc.approve(address(router), amountIn);
        uint256 amountOut = router.swapExactInputSingle(
            address(usdc), address(wbtc), 3000, amountIn, minOut
        );
        vm.stopPrank();

        assertGt(amountOut, 0);
        assertEq(usdc.balanceOf(user), 0);
        assertGt(wbtc.balanceOf(user), 0);
    }

    function test_swapExactInputSingle_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(SwapRouter.ZeroAmount.selector);
        router.swapExactInputSingle(address(usdc), address(wbtc), 3000, 0, 0);
    }

    // ─── Batch swap: swapToPortfolio ─────────────────────────────────────────

    function test_swapToPortfolio_splitDeposit() public {
        uint256 totalUsdc = 63_000e6;
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
        assertGt(outs[0], 0);
        assertGt(outs[1], 0);
        assertEq(wbtc.balanceOf(vault), outs[0]);
        assertEq(weth.balanceOf(vault), outs[1]);
    }

    function test_swapToPortfolio_skipsZeroAmounts() public {
        uint256 totalUsdc = 60_000e6;
        usdc.mint(vault, totalUsdc);

        address[] memory tokensOut = new address[](2);
        uint256[] memory amounts   = new uint256[](2);
        tokensOut[0] = address(wbtc);  amounts[0] = totalUsdc;
        tokensOut[1] = address(weth);  amounts[1] = 0;

        vm.startPrank(vault);
        usdc.approve(address(router), totalUsdc);
        uint256[] memory outs = router.swapToPortfolio(address(usdc), tokensOut, amounts);
        vm.stopPrank();

        assertGt(outs[0], 0);
        assertEq(outs[1], 0);
        assertEq(weth.balanceOf(vault), 0);
    }

    // ─── Batch swap: swapToInputToken ────────────────────────────────────────

    function test_swapToInputToken_batchWithdrawal() public {
        uint256 wbtcAmount = 1e8;
        uint256 wethAmount = 10e18;
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

        assertGt(totalUsdc, 0);
        assertEq(usdc.balanceOf(vault), totalUsdc);
    }

    // ─── Oracle slippage protection ───────────────────────────────────────────

    function test_swapToPortfolio_oracleBlocksSandwich() public {
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
        mockDex.setFillBps(10_000);

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
        tokensOut[0] = address(usdc);
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

    address internal vaultOwner   = makeAddr("vaultOwner");
    address internal feeRecipient = makeAddr("feeRecipient");

    int256 constant USDC_PRICE = 1e8;
    int256 constant WBTC_PRICE = 60_000e8;
    int256 constant WETH_PRICE = 3_000e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin",    "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);

        usdcFeed = new MockAggregator(USDC_PRICE, block.timestamp);
        wbtcFeed = new MockAggregator(WBTC_PRICE, block.timestamp);
        wethFeed = new MockAggregator(WETH_PRICE, block.timestamp);

        mockDex = new MockUniswapRouter();
        router  = new SwapRouter(address(mockDex));

        router.setPriceFeed(address(usdc), address(usdcFeed));
        router.setPriceFeed(address(wbtc), address(wbtcFeed));
        router.setPriceFeed(address(weth), address(wethFeed));
        router.setPoolFee(address(usdc), address(wbtc), 3000);
        router.setPoolFee(address(usdc), address(weth), 500);
        router.setPoolFee(address(wbtc), address(weth), 3000);

        // Whitelist USDC as accepted deposit/withdrawal token.
        router.whitelistToken(address(usdc));

        registry = new RiskTierRegistry();

        address[] memory assets  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        assets[0] = address(wbtc);  weights[0] = 5_000;  feeds[0] = address(wbtcFeed);
        assets[1] = address(weth);  weights[1] = 5_000;  feeds[1] = address(wethFeed);
        registry.createTier(0, "Test Tier", assets, weights, feeds);

        // Factory wires the router into every new vault and authorizes it.
        factory = new VaultFactory(address(router), address(registry), feeRecipient);

        // Factory calls router.authorizeVault() on each new vault — factory must own the router.
        router.transferOwnership(address(factory));

        vm.prank(vaultOwner);
        address vaultAddr = factory.createVault(0, false);
        vault = PortfolioVault(vaultAddr);
        // vault.swapRouter is set and router.authorizedVaults[vault] == true automatically.
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    function test_deposit_swapsUsdcIntoPortfolio() public {
        uint256 depositAmount = 63_000e6;
        usdc.mint(vaultOwner, depositAmount);

        vm.startPrank(vaultOwner);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertGt(wbtc.balanceOf(address(vault)), 0, "vault holds WBTC");
        assertGt(weth.balanceOf(address(vault)), 0, "vault holds WETH");
        assertEq(usdc.balanceOf(address(vault)), 0, "no USDC left in vault");
    }

    function test_deposit_mintsSharesProportionally() public {
        uint256 deposit1 = 60_000e6;
        uint256 deposit2 = 60_000e6;

        usdc.mint(vaultOwner, deposit1 + deposit2);
        vm.startPrank(vaultOwner);
        usdc.approve(address(vault), deposit1 + deposit2);

        uint256 shares1 = vault.deposit(address(usdc), deposit1);
        uint256 shares2 = vault.deposit(address(usdc), deposit2);
        vm.stopPrank();

        assertApproxEqRel(shares1, shares2, 0.01e18, "shares should be proportional");
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────

    function test_withdraw_convertsPortfolioToUsdc() public {
        uint256 depositAmount = 63_000e6;
        usdc.mint(vaultOwner, depositAmount);

        vm.startPrank(vaultOwner);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(address(usdc), depositAmount);

        uint256 shares = vault.balanceOf(vaultOwner);
        assertGt(shares, 0);

        uint256 usdcBefore = usdc.balanceOf(vaultOwner);
        vault.withdraw(address(usdc), shares, block.timestamp, new bytes(0));
        vm.stopPrank();

        assertGt(usdc.balanceOf(vaultOwner) - usdcBefore, 0, "received USDC");
        assertEq(vault.balanceOf(vaultOwner), 0, "shares burned");
    }

    // ─── No router: deposit reverts ───────────────────────────────────────────

    function test_deposit_noRouter_reverts() public {
        // Create a vault via a factory with no swapRouter set.
        VaultFactory noRouterFactory = new VaultFactory(address(0), address(registry), feeRecipient);
        vm.prank(vaultOwner);
        address noRouterVault = noRouterFactory.createVault(0, false);

        usdc.mint(vaultOwner, 1_000e6);
        vm.startPrank(vaultOwner);
        usdc.approve(noRouterVault, 1_000e6);
        vm.expectRevert(PortfolioVault.SwapRouterRequired.selector);
        PortfolioVault(noRouterVault).deposit(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    // ─── SwapRouter access control via vault ─────────────────────────────────

    function test_routerRejects_directCallerNotVault() public {
        address stranger = makeAddr("stranger");
        address[] memory tokensOut = new address[](1);
        uint256[] memory amounts   = new uint256[](1);
        tokensOut[0] = address(wbtc);
        amounts[0]   = 1_000e6;

        vm.prank(stranger);
        vm.expectRevert(SwapRouter.Unauthorized.selector);
        router.swapToPortfolio(address(usdc), tokensOut, amounts);
    }
}
