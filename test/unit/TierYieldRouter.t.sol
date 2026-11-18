// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TierYieldRouter} from "../../src/modules/TierYieldRouter.sol";
import {ISingleAssetYieldStrategy} from "../../src/interfaces/ISingleAssetYieldStrategy.sol";

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

// ─── Mock single-asset strategy: 1:1 units, holds raw tokens ─────────────────

contract MockStrategy is ISingleAssetYieldStrategy {
    address public immutable asset_;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    mapping(address => bool) public authorizedRouters;

    constructor(address asset__) { asset_ = asset__; }

    function asset() external view returns (address) { return asset_; }

    function registerRouter(address router) external {
        authorizedRouters[router] = true;
    }

    function deposit(address vault, uint256 amount) external returns (uint256 shares) {
        MockERC20(asset_).transferFrom(msg.sender, address(this), amount);
        shares = amount;
        sharesOf[vault] += shares;
        totalShares      += shares;
    }

    function withdrawAll(address vault) external returns (uint256 amount) {
        uint256 shares = sharesOf[vault];
        if (shares == 0 || totalShares == 0) return 0;
        uint256 bal = MockERC20(asset_).balanceOf(address(this));
        amount = (bal * shares) / totalShares;
        sharesOf[vault] = 0;
        totalShares     -= shares;
        if (amount > 0) MockERC20(asset_).transfer(msg.sender, amount);
    }

    function valueOf(address vault) external view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 bal = MockERC20(asset_).balanceOf(address(this));
        return (bal * sharesOf[vault]) / totalShares;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract TierYieldRouterTest is Test {
    event StrategySet(address indexed asset, address indexed strategy);

    TierYieldRouter internal router;
    MockERC20       internal token;
    MockStrategy    internal strategy;

    address internal factory = makeAddr("factory");
    address internal vault   = makeAddr("vault");

    function setUp() public {
        token = new MockERC20("Token", "TKN", 18);

        // Deployed by the test contract itself (not `factory`) so the test contract is the
        // Ownable owner for setStrategy() — `factory` is only the separate registerVault()
        // authority, matching TierYieldRouter's constructor(factory_) Ownable(msg.sender) split.
        router = new TierYieldRouter(factory);

        strategy = new MockStrategy(address(token));
        strategy.registerRouter(address(router));

        vm.prank(factory);
        router.registerVault(vault);
    }

    // ─── constructor ─────────────────────────────────────────────────────────

    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(TierYieldRouter.ZeroAddress.selector);
        new TierYieldRouter(address(0));
    }

    // ─── setStrategy ─────────────────────────────────────────────────────────

    function test_setStrategy_onlyOwner_succeeds() public {
        router.setStrategy(address(token), address(strategy));
        assertEq(router.strategyOf(address(token)), address(strategy));
    }

    function test_setStrategy_onlyOwner_reverts() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        router.setStrategy(address(token), address(strategy));
    }

    function test_setStrategy_zeroAsset_reverts() public {
        vm.expectRevert(TierYieldRouter.ZeroAddress.selector);
        router.setStrategy(address(0), address(strategy));
    }

    function test_setStrategy_backToZero_disablesCoverage() public {
        router.setStrategy(address(token), address(strategy));
        assertEq(router.strategyOf(address(token)), address(strategy));

        router.setStrategy(address(token), address(0));
        assertEq(router.strategyOf(address(token)), address(0));
    }

    function test_setStrategy_emitsEvent() public {
        vm.expectEmit(true, true, false, false, address(router));
        emit StrategySet(address(token), address(strategy));
        router.setStrategy(address(token), address(strategy));
    }

    // ─── deposit ─────────────────────────────────────────────────────────────

    function test_deposit_uncoveredAsset_reverts() public {
        token.mint(vault, 1_000e18);
        vm.startPrank(vault);
        token.approve(address(router), 1_000e18);
        vm.expectRevert(TierYieldRouter.StrategyNotConfigured.selector);
        router.deposit(address(token), 1_000e18);
        vm.stopPrank();
    }

    function test_deposit_routesToConfiguredStrategy() public {
        router.setStrategy(address(token), address(strategy));

        token.mint(vault, 1_000e18);
        vm.startPrank(vault);
        token.approve(address(router), 1_000e18);
        router.deposit(address(token), 1_000e18);
        vm.stopPrank();

        assertEq(token.balanceOf(address(strategy)), 1_000e18);
        assertEq(strategy.sharesOf(vault), 1_000e18);
    }

    function test_deposit_onlyAuthorizedVault_reverts() public {
        router.setStrategy(address(token), address(strategy));

        address rogue = makeAddr("rogue");
        token.mint(rogue, 1_000e18);
        vm.startPrank(rogue);
        token.approve(address(router), 1_000e18);
        vm.expectRevert(TierYieldRouter.Unauthorized.selector);
        router.deposit(address(token), 1_000e18);
        vm.stopPrank();
    }

    // ─── withdrawAll ─────────────────────────────────────────────────────────

    function test_withdrawAll_uncoveredAsset_reverts() public {
        vm.prank(vault);
        vm.expectRevert(TierYieldRouter.StrategyNotConfigured.selector);
        router.withdrawAll(address(token));
    }

    function test_withdrawAll_routesToConfiguredStrategy() public {
        router.setStrategy(address(token), address(strategy));

        token.mint(vault, 1_000e18);
        vm.startPrank(vault);
        token.approve(address(router), 1_000e18);
        router.deposit(address(token), 1_000e18);

        uint256 out = router.withdrawAll(address(token));
        vm.stopPrank();

        assertEq(out, 1_000e18);
        assertEq(token.balanceOf(vault), 1_000e18);
        assertEq(strategy.sharesOf(vault), 0);
    }

    function test_withdrawAll_onlyAuthorizedVault_reverts() public {
        router.setStrategy(address(token), address(strategy));

        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert(TierYieldRouter.Unauthorized.selector);
        router.withdrawAll(address(token));
    }

    // ─── valueOf ─────────────────────────────────────────────────────────────

    function test_valueOf_uncoveredAsset_returnsZeroWithoutReverting() public view {
        assertEq(router.valueOf(vault, address(token)), 0);
    }

    function test_valueOf_coveredAsset_returnsStrategyValue() public {
        router.setStrategy(address(token), address(strategy));

        token.mint(vault, 1_000e18);
        vm.startPrank(vault);
        token.approve(address(router), 1_000e18);
        router.deposit(address(token), 1_000e18);
        vm.stopPrank();

        assertEq(router.valueOf(vault, address(token)), 1_000e18);
    }

    // ─── registerVault ───────────────────────────────────────────────────────

    function test_registerVault_onlyFactory_reverts() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(TierYieldRouter.Unauthorized.selector);
        router.registerVault(makeAddr("newVault"));
    }

    function test_registerVault_byFactory_succeeds() public {
        address newVault = makeAddr("newVault");
        vm.prank(factory);
        router.registerVault(newVault);
        assertTrue(router.authorizedVaults(newVault));
    }
}
