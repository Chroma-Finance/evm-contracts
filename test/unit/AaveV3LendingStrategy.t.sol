// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3LendingStrategy, IAavePool} from "../../src/strategies/AaveV3LendingStrategy.sol";
import {SingleAssetYieldStrategy} from "../../src/modules/SingleAssetYieldStrategy.sol";
import {FeeManager} from "../../src/utils/FeeManager.sol";

// ─── Mock ERC-20 (with a permissionless burn, matching the permissionless mint already
//     used across this repo's test mocks) ────────────────────────────────────

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
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount; totalSupply -= amount; emit Transfer(from, address(0), amount);
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

// ─── Mock Aave V3 Pool: 1:1 aToken mint/burn, no yield accrual ───────────────
//
// Matches IAavePool's supply/withdraw/getReserveData exactly (defined in
// AaveV3LendingStrategy.sol). Yield accrual itself is exercised against the real, live Aave V3
// Pool in test/fork/AaveV3LendingStrategyFork.t.sol — this mock only needs to prove
// AaveV3LendingStrategy's own accounting (aToken delta measurement, on-chain aToken
// derivation, max-withdraw handling) is wired correctly.

contract MockAavePool is IAavePool {
    mapping(address => address) public aTokenOf;

    function setAToken(address underlying, address aToken) external {
        aTokenOf[underlying] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockERC20(aTokenOf[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        MockERC20 aToken = MockERC20(aTokenOf[asset]);
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 actual = (amount == type(uint256).max || amount > bal) ? bal : amount;

        aToken.burn(msg.sender, actual);
        MockERC20(asset).transfer(to, actual);
        return actual;
    }

    function getReserveData(address asset) external view override returns (ReserveData memory data) {
        data.aTokenAddress = aTokenOf[asset];
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract AaveV3LendingStrategyTest is Test {
    MockERC20              internal underlying;
    MockERC20               internal aToken;
    MockAavePool             internal pool;
    FeeManager               internal feeManager;
    AaveV3LendingStrategy    internal strategy;

    address internal router   = makeAddr("router");
    address internal vault1   = makeAddr("vault1");
    address internal vault2   = makeAddr("vault2");
    address internal treasury = makeAddr("treasury");
    address internal devFund  = makeAddr("devFund");

    function setUp() public {
        underlying = new MockERC20("USD Coin", "USDC", 6);
        aToken     = new MockERC20("Aave USDC", "aUSDC", 6);
        pool       = new MockAavePool();
        pool.setAToken(address(underlying), address(aToken));

        feeManager = new FeeManager(treasury, devFund);

        strategy = new AaveV3LendingStrategy(address(feeManager), address(underlying), address(pool));
        strategy.registerRouter(router);
    }

    function _deposit(address vault, uint256 amount) internal returns (uint256 shares) {
        underlying.mint(router, amount);
        vm.startPrank(router);
        underlying.approve(address(strategy), amount);
        shares = strategy.deposit(vault, amount);
        vm.stopPrank();
    }

    // ─── constructor ─────────────────────────────────────────────────────────

    function test_constructor_derivesATokenFromPoolReserveData() public view {
        assertEq(address(strategy.aToken()), address(aToken));
    }

    function test_constructor_zeroAavePool_reverts() public {
        vm.expectRevert(SingleAssetYieldStrategy.ZeroAddress.selector);
        new AaveV3LendingStrategy(address(feeManager), address(underlying), address(0));
    }

    function test_constructor_unlistedReserve_reverts() public {
        // Fresh pool with no aToken configured for `underlying` — mirrors Aave returning the
        // zero address for an unlisted/unconfigured reserve.
        MockAavePool freshPool = new MockAavePool();
        vm.expectRevert(SingleAssetYieldStrategy.ZeroAddress.selector);
        new AaveV3LendingStrategy(address(feeManager), address(underlying), address(freshPool));
    }

    // ─── deposit: share math (exact virtual-offset formula) ─────────────────

    function test_deposit_firstDeposit_mintsUnitsAddedAsShares() public {
        // totalShares=0, priorTotalUnits=0 -> shares = unitsAdded*(0+1)/(0+1) = unitsAdded.
        uint256 shares = _deposit(vault1, 1_000e6);
        assertEq(shares, 1_000e6);
        assertEq(strategy.sharesOf(vault1), 1_000e6);
        assertEq(strategy.totalShares(), 1_000e6);
        assertEq(aToken.balanceOf(address(strategy)), 1_000e6);
    }

    function test_deposit_secondDeposit_matchesExactVirtualOffsetFormula() public {
        _deposit(vault1, 1_000e6);

        // Donate extra aToken directly to the strategy so priorTotalUnits != totalShares,
        // exercising the mulDiv formula for real instead of the degenerate 1:1 first-deposit case.
        aToken.mint(address(strategy), 500e6);

        uint256 priorTotalUnits  = aToken.balanceOf(address(strategy));
        uint256 priorTotalShares = strategy.totalShares();

        uint256 depositAmount = 300e6; // == unitsAdded, mock aToken mints 1:1
        uint256 expectedShares = (depositAmount * (priorTotalShares + 1)) / (priorTotalUnits + 1);

        uint256 shares2 = _deposit(vault2, depositAmount);
        assertEq(shares2, expectedShares);
        assertEq(strategy.totalShares(), priorTotalShares + expectedShares);
    }

    // ─── withdrawAll: full burn, no partial path ─────────────────────────────

    function test_withdrawAll_burnsAllSharesReturnsFullAmount() public {
        uint256 shares = _deposit(vault1, 1_000e6);
        assertGt(shares, 0);

        vm.prank(router);
        uint256 amount = strategy.withdrawAll(vault1);

        assertEq(amount, 1_000e6);
        assertEq(strategy.sharesOf(vault1), 0);
        assertEq(strategy.totalShares(), 0);
        assertEq(underlying.balanceOf(router), 1_000e6);
    }

    function test_withdrawAll_zeroShares_reverts() public {
        vm.prank(router);
        vm.expectRevert(SingleAssetYieldStrategy.ZeroShares.selector);
        strategy.withdrawAll(vault1);
    }

    // ─── two vaults: one withdrawing must not affect the other's valueOf ────
    //
    // Direct regression test for the exact bug class found in UniswapV3LPStrategy (one
    // vault's redemption silently sweeping another vault's unrealized share of a shared
    // position). The architecture here makes it structurally different — each vault's claim
    // is its own `sharesOf` entry redeemed against the strategy's own aToken balance, not a
    // single shared position's fee-growth delta — but this is still worth asserting directly.

    function test_withdrawAll_twoVaults_oneWithdrawDoesNotAffectOthersValueOf() public {
        _deposit(vault1, 1_000e6);
        _deposit(vault2, 1_000e6);

        uint256 valueBBefore = strategy.valueOf(vault2);
        assertEq(valueBBefore, 1_000e6);

        vm.prank(router);
        strategy.withdrawAll(vault1);

        uint256 valueBAfter = strategy.valueOf(vault2);
        assertEq(valueBAfter, valueBBefore, "vault2 valueOf changed after vault1 withdrew");
        assertEq(strategy.sharesOf(vault2), 1_000e6, "vault2 shares changed after vault1 withdrew");
    }

    // ─── access control ──────────────────────────────────────────────────────

    function test_deposit_onlyAuthorizedRouter_reverts() public {
        address rogue = makeAddr("rogue");
        underlying.mint(rogue, 1_000e6);
        vm.startPrank(rogue);
        underlying.approve(address(strategy), 1_000e6);
        vm.expectRevert(SingleAssetYieldStrategy.Unauthorized.selector);
        strategy.deposit(vault1, 1_000e6);
        vm.stopPrank();
    }

    function test_withdrawAll_onlyAuthorizedRouter_reverts() public {
        _deposit(vault1, 1_000e6);
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert(SingleAssetYieldStrategy.Unauthorized.selector);
        strategy.withdrawAll(vault1);
    }

    function test_registerRouter_onlyOwner_reverts() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        strategy.registerRouter(makeAddr("newRouter"));
    }

    function test_registerRouter_onlyOwner_succeeds() public {
        address newRouter = makeAddr("newRouter");
        strategy.registerRouter(newRouter);
        assertTrue(strategy.authorizedRouters(newRouter));
    }

    // ─── emergencyWithdrawAll ────────────────────────────────────────────────

    function test_emergencyWithdrawAll_pullsAllBackAndPauses() public {
        _deposit(vault1, 1_000e6);
        assertEq(aToken.balanceOf(address(strategy)), 1_000e6);

        strategy.emergencyWithdrawAll();

        assertTrue(strategy.paused());
        assertEq(aToken.balanceOf(address(strategy)), 0);
        assertEq(underlying.balanceOf(address(strategy)), 1_000e6);
    }

    function test_pause_blocksDeposit() public {
        strategy.emergencyWithdrawAll();

        underlying.mint(router, 1_000e6);
        vm.startPrank(router);
        underlying.approve(address(strategy), 1_000e6);
        vm.expectRevert(SingleAssetYieldStrategy.Paused.selector);
        strategy.deposit(vault1, 1_000e6);
        vm.stopPrank();
    }
}
