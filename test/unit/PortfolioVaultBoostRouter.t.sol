// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {GuardianModule} from "../../src/modules/GuardianModule.sol";
import {TierYieldRouter} from "../../src/modules/TierYieldRouter.sol";
import {ISingleAssetYieldStrategy} from "../../src/interfaces/ISingleAssetYieldStrategy.sol";

/**
 * @notice Covers the new per-asset router Boost model added alongside {TierYieldRouter} and
 *         {SingleAssetYieldStrategy}: a tier can have a mix of covered (strategy-wired) and
 *         uncovered (left in the vault) assets, unlike the old all-or-nothing batched
 *         {YieldOptimizerCore} model exercised by test/unit/PortfolioVaultBoost.t.sol (that
 *         file's own tests were adapted in place — its single-asset fixture continues to pass
 *         unmodified against a router-shaped mock). This file adds a NEW, separate two-asset
 *         fixture instead of extending that one, since "one asset covered, one not" has no
 *         analogue in a single-token portfolio.
 */

// ─── Mock ERC-20 ─────────────────────────────────────────────────────────────

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
        totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; emit Transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount); return true;
    }
}

// ─── Mock Chainlink aggregator ($1 price, 8 dec) ──────────────────────────────

contract MockAggregator {
    uint80 public roundId = 1;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, 1e8, 0, block.timestamp, roundId);
    }
}

// ─── Mock swap router (1:1 amount passthrough) ───────────────────────────────

contract MockSwapRouter {
    function swapToPortfolio(
        address tokenIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn
    ) external returns (uint256[] memory amountsOut) {
        uint256 total;
        for (uint256 i = 0; i < amountsIn.length; i++) total += amountsIn[i];
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), total);
        amountsOut = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < tokensOut.length; i++) {
            amountsOut[i] = amountsIn[i];
            if (amountsIn[i] > 0) MockERC20(tokensOut[i]).mint(msg.sender, amountsIn[i]);
        }
    }

    function swapToInputToken(
        address[] calldata tokensIn,
        uint256[] calldata amountsIn,
        address tokenOut
    ) external returns (uint256 totalOut) {
        for (uint256 i = 0; i < tokensIn.length; i++) {
            if (amountsIn[i] == 0) continue;
            MockERC20(tokensIn[i]).transferFrom(msg.sender, address(this), amountsIn[i]);
            MockERC20(tokenOut).mint(msg.sender, amountsIn[i]);
            totalOut += amountsIn[i];
        }
    }

    function authorizeVault(address) external {}
}

// ─── Mock single-asset strategy: 1:1 units, holds raw tokens, keyed by vault ─

contract MockSingleAssetYieldStrategy is ISingleAssetYieldStrategy {
    address public immutable underlying;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function registerRouter(address) external {}

    function deposit(address vault, uint256 amount) external returns (uint256 shares) {
        MockERC20(underlying).transferFrom(msg.sender, address(this), amount);
        shares = amount;
        sharesOf[vault] += shares;
        totalShares      += shares;
    }

    function withdrawAll(address vault) external returns (uint256 amount) {
        uint256 shares = sharesOf[vault];
        if (shares == 0 || totalShares == 0) return 0;
        uint256 bal = MockERC20(underlying).balanceOf(address(this));
        amount = (bal * shares) / totalShares;
        sharesOf[vault] = 0;
        totalShares     -= shares;
        if (amount > 0) MockERC20(underlying).transfer(msg.sender, amount);
    }

    function valueOf(address vault) external view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 bal = MockERC20(underlying).balanceOf(address(this));
        return (bal * sharesOf[vault]) / totalShares;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract PortfolioVaultBoostRouterTest is Test {
    event BoostEntered(address indexed owner, uint256[] amounts);
    event BoostExited(address indexed owner, uint256[] amounts);

    MockERC20  internal usdc;
    MockERC20  internal foo; // portfolio index 0
    MockERC20  internal bar; // portfolio index 1

    MockAggregator internal fooFeed;
    MockAggregator internal barFeed;
    MockSwapRouter internal mockSwap;
    GuardianModule internal gm;

    TierYieldRouter               internal router;
    MockSingleAssetYieldStrategy  internal fooStrategy;
    MockSingleAssetYieldStrategy  internal barStrategy;

    address internal factory     = makeAddr("factory");
    address internal vaultOwner  = makeAddr("vaultOwner");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint256 constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 constant EXPECTED_USD   = 1_000e8;
    uint256 constant MIN_BOOST_USD  = 500e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        foo  = new MockERC20("Foo", "FOO", 6);
        bar  = new MockERC20("Bar", "BAR", 6);
        fooFeed = new MockAggregator();
        barFeed = new MockAggregator();
        mockSwap = new MockSwapRouter();
        gm = new GuardianModule();

        router = new TierYieldRouter(factory);
        fooStrategy = new MockSingleAssetYieldStrategy(address(foo));
        barStrategy = new MockSingleAssetYieldStrategy(address(bar));
    }

    /// @dev Deploys a fresh 2-token (foo/bar, 50/50) vault wired to `router`, with `router`'s
    ///      per-asset strategy coverage configured per the two bools, and registers the vault
    ///      with the router the same way VaultFactory.createVault() does.
    function _newVault(bool coverFoo, bool coverBar) internal returns (PortfolioVault v) {
        router.setStrategy(address(foo), coverFoo ? address(fooStrategy) : address(0));
        router.setStrategy(address(bar), coverBar ? address(barStrategy) : address(0));

        address[] memory tokens  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        tokens[0] = address(foo); weights[0] = 5_000; feeds[0] = address(fooFeed);
        tokens[1] = address(bar); weights[1] = 5_000; feeds[1] = address(barFeed);

        v = new PortfolioVault();
        v.initialize(
            vaultOwner, 0, feeRecipient,
            address(0),          // eventNotifier — off for unit tests
            address(gm),
            address(0),          // recoveryModule
            address(mockSwap),
            address(router),
            MIN_BOOST_USD,
            tokens, weights, feeds
        );

        vm.prank(factory);
        router.registerVault(address(v));
    }

    function _deposit(PortfolioVault v, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(vaultOwner, amount);
        vm.startPrank(vaultOwner);
        usdc.approve(address(v), amount);
        shares = v.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── one asset covered, one not ──────────────────────────────────────────

    function test_enterBoost_onlyOneAssetCovered_movesOnlyCoveredAsset() public {
        PortfolioVault v = _newVault(true, false); // foo covered, bar stays in vault
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));
        assertGt(fooBalBefore, 0);
        assertGt(barBalBefore, 0);

        uint256 totalBefore = v.totalAssets();

        vm.prank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));

        assertTrue(v.boosted());
        assertEq(foo.balanceOf(address(v)), 0, "covered asset should have left the vault");
        assertEq(foo.balanceOf(address(fooStrategy)), fooBalBefore, "covered asset not in its strategy");
        assertEq(bar.balanceOf(address(v)), barBalBefore, "uncovered asset must stay in vault, untouched");
        assertEq(bar.balanceOf(address(barStrategy)), 0, "uncovered asset must never reach a strategy");

        // totalAssets() must correctly sum the router-held (foo) and vault-held (bar) sources.
        assertEq(v.totalAssets(), totalBefore);
        assertEq(v.totalAssets(), EXPECTED_USD);
    }

    function test_enterBoost_onlyOneAssetCovered_eventHasZeroForUncoveredAsset() public {
        PortfolioVault v = _newVault(true, false);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));

        uint256[] memory expected = new uint256[](2);
        expected[0] = fooBalBefore;
        expected[1] = 0;

        vm.expectEmit(true, false, false, true, address(v));
        emit BoostEntered(vaultOwner, expected);

        vm.prank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));
    }

    function test_exitBoost_onlyOneAssetCovered_restoresCoveredNoopsUncovered() public {
        PortfolioVault v = _newVault(true, false);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));

        vm.startPrank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));
        v.exitBoost();
        vm.stopPrank();

        assertFalse(v.boosted());
        assertEq(foo.balanceOf(address(v)), fooBalBefore, "covered asset not restored to vault");
        assertEq(foo.balanceOf(address(fooStrategy)), 0, "covered asset left behind in strategy");
        assertEq(bar.balanceOf(address(v)), barBalBefore, "uncovered asset balance changed by exitBoost");
    }

    // ─── both assets covered ─────────────────────────────────────────────────

    function test_enterBoost_bothAssetsCovered_movesBoth() public {
        PortfolioVault v = _newVault(true, true);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));

        vm.prank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));

        assertEq(foo.balanceOf(address(v)), 0);
        assertEq(bar.balanceOf(address(v)), 0);
        assertEq(foo.balanceOf(address(fooStrategy)), fooBalBefore);
        assertEq(bar.balanceOf(address(barStrategy)), barBalBefore);
        assertEq(v.totalAssets(), EXPECTED_USD);
    }

    function test_exitBoost_bothAssetsCovered_restoresBoth() public {
        PortfolioVault v = _newVault(true, true);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));

        vm.startPrank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));
        v.exitBoost();
        vm.stopPrank();

        assertFalse(v.boosted());
        assertEq(foo.balanceOf(address(v)), fooBalBefore);
        assertEq(bar.balanceOf(address(v)), barBalBefore);
    }

    // ─── neither asset covered ───────────────────────────────────────────────

    function test_enterBoost_neitherAssetCovered_succeedsButNothingMoves() public {
        PortfolioVault v = _newVault(false, false);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));
        uint256 totalBefore  = v.totalAssets();

        vm.prank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0)); // must not revert

        assertTrue(v.boosted());
        assertEq(foo.balanceOf(address(v)), fooBalBefore, "vault balance moved despite no coverage");
        assertEq(bar.balanceOf(address(v)), barBalBefore, "vault balance moved despite no coverage");
        assertEq(v.totalAssets(), totalBefore, "totalAssets() changed despite no coverage");
        assertEq(v.totalAssets(), EXPECTED_USD);
    }

    function test_exitBoost_neitherAssetCovered_succeedsAsNoop() public {
        PortfolioVault v = _newVault(false, false);
        _deposit(v, DEPOSIT_AMOUNT);

        uint256 fooBalBefore = foo.balanceOf(address(v));
        uint256 barBalBefore = bar.balanceOf(address(v));

        vm.startPrank(vaultOwner);
        v.enterBoost(block.timestamp, new bytes(0));
        v.exitBoost(); // must not revert even though nothing was ever moved
        vm.stopPrank();

        assertFalse(v.boosted());
        assertEq(foo.balanceOf(address(v)), fooBalBefore);
        assertEq(bar.balanceOf(address(v)), barBalBefore);
    }
}
