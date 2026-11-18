// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldOptimizerCore} from "../../src/modules/YieldOptimizerCore.sol";
import {FeeManager} from "../../src/utils/FeeManager.sol";

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

// ─── Mock strategy: single asset, 1:1 units == token balance ─────────────────

contract MockYieldStrategy is YieldOptimizerCore {
    uint256 public pendingYield;

    constructor(address factory_, address feeManager_, address[] memory assets_)
        YieldOptimizerCore(factory_, feeManager_, assets_)
    {}

    /// @dev Test-only hook: marks `amount` of the strategy's current token balance as
    ///      harvestable yield (simulating rewards that accrued externally).
    function setPendingYield(uint256 amount) external {
        pendingYield = amount;
    }

    function _deploy(uint256[] calldata amounts) internal pure override returns (uint256 unitsAdded) {
        unitsAdded = amounts[0];
    }

    function _redeem(uint256 shares, uint256 priorTotalShares) internal view override returns (uint256[] memory amountsOut) {
        amountsOut = new uint256[](1);
        uint256 bal = IERC20(assetTokens[0]).balanceOf(address(this));
        amountsOut[0] = (bal * shares) / priorTotalShares;
    }

    function _totalUnits() internal view override returns (uint256) {
        return IERC20(assetTokens[0]).balanceOf(address(this));
    }

    function _totalAssets() internal view override returns (uint256[] memory result) {
        result = new uint256[](1);
        result[0] = IERC20(assetTokens[0]).balanceOf(address(this));
    }

    function _harvest() internal override {
        uint256 yieldAmount = pendingYield;
        pendingYield = 0;
        if (yieldAmount > 0) {
            _collectBoostFee(assetTokens[0], yieldAmount);
        }
    }

    function _emergencyExit() internal pure override {
        // Mock holds raw tokens directly — nothing external to pull back.
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract YieldOptimizerCoreTest is Test {
    event Deposited(address indexed vault, uint256 shares, uint256[] amounts);
    event Withdrawn(address indexed vault, uint256 shares, uint256[] amounts);

    MockYieldStrategy internal strategy;
    MockERC20         internal token;
    FeeManager        internal feeManager;

    address internal factory  = makeAddr("factory");
    address internal vault1   = makeAddr("vault1");
    address internal vault2   = makeAddr("vault2");
    address internal treasury = makeAddr("treasury");
    address internal devFund  = makeAddr("devFund");

    function setUp() public {
        token      = new MockERC20("Token", "TKN", 18);
        feeManager = new FeeManager(treasury, devFund);

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(factory);
        strategy = new MockYieldStrategy(factory, address(feeManager), assets);

        vm.startPrank(factory);
        strategy.registerVault(vault1);
        strategy.registerVault(vault2);
        vm.stopPrank();
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _deposit(address vault, uint256 amount) internal returns (uint256 shares) {
        token.mint(vault, amount);
        vm.startPrank(vault);
        token.approve(address(strategy), amount);
        shares = strategy.deposit(_amounts(amount));
        vm.stopPrank();
    }

    // ─── constructor ─────────────────────────────────────────────────────────

    function test_constructor_zeroFactory_reverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        vm.expectRevert(YieldOptimizerCore.ZeroAddress.selector);
        new MockYieldStrategy(address(0), address(feeManager), assets);
    }

    function test_constructor_zeroFeeManager_reverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        vm.expectRevert(YieldOptimizerCore.ZeroAddress.selector);
        new MockYieldStrategy(factory, address(0), assets);
    }

    // ─── deposit: share accounting ──────────────────────────────────────────

    function test_deposit_firstDeposit_mintsUnitsAddedAsShares() public {
        // totalShares=0, unitsBefore=0 -> shares = amount * (0+1)/(0+1) = amount
        uint256 shares = _deposit(vault1, 1_000e18);
        assertEq(shares, 1_000e18);
        assertEq(strategy.sharesOf(vault1), 1_000e18);
        assertEq(strategy.totalShares(), 1_000e18);
    }

    function test_deposit_secondDeposit_provesProportionalShares() public {
        _deposit(vault1, 1_000e18);
        // unitsBefore=1000e18, totalShares=1000e18 -> shares = 1000e18*(1000e18+1)/(1000e18+1) = 1000e18
        uint256 shares2 = _deposit(vault2, 1_000e18);
        assertEq(shares2, 1_000e18);
        assertEq(strategy.totalShares(), 2_000e18);
    }

    function test_deposit_transfersTokensIn() public {
        _deposit(vault1, 1_000e18);
        assertEq(token.balanceOf(address(strategy)), 1_000e18);
    }

    function test_deposit_emitsEvent() public {
        token.mint(vault1, 1_000e18);
        vm.startPrank(vault1);
        token.approve(address(strategy), 1_000e18);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit Deposited(vault1, 1_000e18, _amounts(1_000e18));
        strategy.deposit(_amounts(1_000e18));
        vm.stopPrank();
    }

    function test_deposit_arrayLengthMismatch_reverts() public {
        token.mint(vault1, 1_000e18);
        vm.startPrank(vault1);
        token.approve(address(strategy), 1_000e18);
        vm.expectRevert(YieldOptimizerCore.ArrayLengthMismatch.selector);
        strategy.deposit(new uint256[](2));
        vm.stopPrank();
    }

    // ─── withdraw: share accounting ─────────────────────────────────────────

    function test_withdraw_burnsSharesAndReturnsProportionalAmount() public {
        _deposit(vault1, 1_000e18);
        uint256 shares = strategy.sharesOf(vault1);

        vm.prank(vault1);
        uint256[] memory out = strategy.withdraw(shares);

        assertEq(out[0], 1_000e18);
        assertEq(strategy.sharesOf(vault1), 0);
        assertEq(strategy.totalShares(), 0);
        assertEq(token.balanceOf(vault1), 1_000e18);
    }

    function test_withdraw_partial_proRata() public {
        _deposit(vault1, 1_000e18);
        uint256 half = strategy.sharesOf(vault1) / 2;

        vm.prank(vault1);
        uint256[] memory out = strategy.withdraw(half);

        assertEq(out[0], 500e18);
        assertEq(strategy.sharesOf(vault1), 500e18);
    }

    function test_withdraw_zeroShares_reverts() public {
        vm.prank(vault1);
        vm.expectRevert(YieldOptimizerCore.ZeroShares.selector);
        strategy.withdraw(0);
    }

    function test_withdraw_exceedsBalance_reverts() public {
        _deposit(vault1, 1_000e18);
        uint256 shares = strategy.sharesOf(vault1);
        vm.prank(vault1);
        vm.expectRevert(YieldOptimizerCore.InsufficientShares.selector);
        strategy.withdraw(shares + 1);
    }

    function test_withdraw_emitsEvent() public {
        _deposit(vault1, 1_000e18);
        uint256 shares = strategy.sharesOf(vault1);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit Withdrawn(vault1, shares, _amounts(1_000e18));
        vm.prank(vault1);
        strategy.withdraw(shares);
    }

    // ─── inflation attack resistance ────────────────────────────────────────

    function test_deposit_afterDonation_victimStillReceivesFairNonZeroShares() public {
        // Attacker deposits a small amount first.
        uint256 attackerShares = _deposit(vault1, 1);
        assertEq(attackerShares, 1);

        // Attacker donates directly to the strategy, bypassing deposit(), inflating
        // _totalUnits() (== token balance for this mock) relative to totalShares.
        token.mint(address(strategy), 5_000e18);
        assertEq(strategy.totalShares(), 1);
        assertEq(token.balanceOf(address(strategy)), 1 + 5_000e18);

        // Victim deposits a normal amount. The mulDiv virtual +1 offset on both totalShares
        // and unitsBefore means the victim's shares are computed from the *same* inflated
        // ratio the attacker paid to create — the attacker cannot extract more value than
        // they donated, and the victim's mint is never silently zeroed by the offset itself.
        uint256 unitsBefore  = token.balanceOf(address(strategy));
        uint256 sharesBefore = strategy.totalShares();
        uint256 depositAmount = 10_000e18;

        uint256 expectedShares = (depositAmount * (sharesBefore + 1)) / (unitsBefore + 1);

        uint256 victimShares = _deposit(vault2, depositAmount);
        assertEq(victimShares, expectedShares);

        // Victim's claim, redeemed immediately, must be worth what the formula promised —
        // no silent additional loss beyond the expected proportional rounding.
        vm.prank(vault2);
        uint256[] memory out = strategy.withdraw(victimShares);
        uint256 totalUnitsAfterDeposit = unitsBefore + depositAmount;
        uint256 totalSharesAfterDeposit = sharesBefore + victimShares;
        uint256 expectedOut = (totalUnitsAfterDeposit * victimShares) / totalSharesAfterDeposit;
        assertEq(out[0], expectedOut);
    }

    function test_deposit_belowMinimum_zeroSharesReverts() public {
        // Inflate the pool so 1 wei of deposit rounds down to 0 shares.
        _deposit(vault1, 1_000e18);
        token.mint(address(strategy), 1_000_000_000e18);

        token.mint(vault2, 1);
        vm.startPrank(vault2);
        token.approve(address(strategy), 1);
        vm.expectRevert(YieldOptimizerCore.BelowMinimum.selector);
        strategy.deposit(_amounts(1));
        vm.stopPrank();
    }

    // ─── access control ──────────────────────────────────────────────────────

    function test_deposit_unauthorizedVault_reverts() public {
        address rogue = makeAddr("rogue");
        token.mint(rogue, 1_000e18);
        vm.startPrank(rogue);
        token.approve(address(strategy), 1_000e18);
        vm.expectRevert(YieldOptimizerCore.Unauthorized.selector);
        strategy.deposit(_amounts(1_000e18));
        vm.stopPrank();
    }

    function test_withdraw_unauthorizedVault_reverts() public {
        _deposit(vault1, 1_000e18);
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert(YieldOptimizerCore.Unauthorized.selector);
        strategy.withdraw(1);
    }

    function test_registerVault_onlyFactory_reverts() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(YieldOptimizerCore.Unauthorized.selector);
        strategy.registerVault(makeAddr("someVault"));
    }

    function test_registerVault_byFactory_succeeds() public {
        address newVault = makeAddr("newVault");
        vm.prank(factory);
        strategy.registerVault(newVault);
        assertTrue(strategy.authorizedVaults(newVault));
    }

    // ─── pause ───────────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(strategy.owner());
        strategy.emergencyWithdrawAll();
        assertTrue(strategy.paused());

        token.mint(vault1, 1_000e18);
        vm.startPrank(vault1);
        token.approve(address(strategy), 1_000e18);
        vm.expectRevert(YieldOptimizerCore.Paused.selector);
        strategy.deposit(_amounts(1_000e18));
        vm.stopPrank();
    }

    function test_pause_doesNotBlockWithdraw() public {
        _deposit(vault1, 1_000e18);
        uint256 shares = strategy.sharesOf(vault1);

        vm.prank(strategy.owner());
        strategy.emergencyWithdrawAll();
        assertTrue(strategy.paused());

        vm.prank(vault1);
        uint256[] memory out = strategy.withdraw(shares); // must not revert
        assertEq(out[0], 1_000e18);
    }

    // ─── boost fee ───────────────────────────────────────────────────────────

    function test_harvest_skimsBoostFeeToFeeManager() public {
        _deposit(vault1, 1_000e18);

        uint256 yieldAmount = 100e18;
        token.mint(address(strategy), yieldAmount);
        strategy.setPendingYield(yieldAmount);

        uint256 expectedFee = (yieldAmount * strategy.boostFeeBps()) / strategy.BPS_DENOMINATOR();

        strategy.harvest(); // permissionless

        assertEq(feeManager.collectedFees(address(token)), expectedFee);
        assertEq(token.balanceOf(address(feeManager)), expectedFee);
    }

    function test_setBoostFeeBps_capped() public {
        vm.prank(strategy.owner());
        vm.expectRevert(YieldOptimizerCore.ExceedsMax.selector);
        strategy.setBoostFeeBps(3_001);
    }

    function test_setBoostFeeBps_onlyOwner_reverts() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        strategy.setBoostFeeBps(1_000);
    }
}
