// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

// Minimal ERC-20 mock for tests.
contract MockERC20 {
    string public name     = "Mock USDC";
    string public symbol   = "USDC";
    uint8  public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

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

contract VaultFactoryMultiTierTest is Test {
    VaultFactory      internal factory;
    RiskTierRegistry  internal registry;
    MockERC20         internal usdc;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal userA        = makeAddr("userA");
    address internal userB        = makeAddr("userB");

    // Dummy token addresses used in tier configurations.
    address internal WBTC  = makeAddr("WBTC");
    address internal WETH  = makeAddr("WETH");
    address internal XAUT  = makeAddr("XAUT");
    address internal PAXG  = makeAddr("PAXG");
    address internal STETH = makeAddr("stETH");
    address internal ALTS  = makeAddr("ALTS");

    // Dummy Chainlink feed placeholders (zero-address is fine for unit tests).
    address internal FEED_WBTC  = makeAddr("feed_wbtc");
    address internal FEED_WETH  = makeAddr("feed_weth");
    address internal FEED_XAUT  = makeAddr("feed_xaut");
    address internal FEED_PAXG  = makeAddr("feed_paxg");
    address internal FEED_STETH = makeAddr("feed_steth");
    address internal FEED_ALTS  = makeAddr("feed_alts");

    function setUp() public {
        usdc     = new MockERC20();
        registry = new RiskTierRegistry();

        // Tier 0 — Low Risk: 40% WBTC | 30% XAUT | 30% PAXG
        address[] memory t0Assets = new address[](3);
        uint256[] memory t0Weights = new uint256[](3);
        address[] memory t0Feeds   = new address[](3);
        t0Assets[0] = WBTC;  t0Weights[0] = 4_000; t0Feeds[0] = FEED_WBTC;
        t0Assets[1] = XAUT;  t0Weights[1] = 3_000; t0Feeds[1] = FEED_XAUT;
        t0Assets[2] = PAXG;  t0Weights[2] = 3_000; t0Feeds[2] = FEED_PAXG;
        registry.createTier(0, "Low Risk", t0Assets, t0Weights, t0Feeds);

        // Tier 1 — Medium Risk: 25/25/20/20/10
        address[] memory t1Assets  = new address[](5);
        uint256[] memory t1Weights = new uint256[](5);
        address[] memory t1Feeds   = new address[](5);
        t1Assets[0] = WBTC;  t1Weights[0] = 2_500; t1Feeds[0] = FEED_WBTC;
        t1Assets[1] = WETH;  t1Weights[1] = 2_500; t1Feeds[1] = FEED_WETH;
        t1Assets[2] = XAUT;  t1Weights[2] = 2_000; t1Feeds[2] = FEED_XAUT;
        t1Assets[3] = PAXG;  t1Weights[3] = 2_000; t1Feeds[3] = FEED_PAXG;
        t1Assets[4] = STETH; t1Weights[4] = 1_000; t1Feeds[4] = FEED_STETH;
        registry.createTier(1, "Medium Risk", t1Assets, t1Weights, t1Feeds);

        // Tier 2 — High Risk: 25/25/15/10/10/15
        address[] memory t2Assets  = new address[](6);
        uint256[] memory t2Weights = new uint256[](6);
        address[] memory t2Feeds   = new address[](6);
        t2Assets[0] = WBTC;  t2Weights[0] = 2_500; t2Feeds[0] = FEED_WBTC;
        t2Assets[1] = WETH;  t2Weights[1] = 2_500; t2Feeds[1] = FEED_WETH;
        t2Assets[2] = STETH; t2Weights[2] = 1_500; t2Feeds[2] = FEED_STETH;
        t2Assets[3] = XAUT;  t2Weights[3] = 1_000; t2Feeds[3] = FEED_XAUT;
        t2Assets[4] = PAXG;  t2Weights[4] = 1_000; t2Feeds[4] = FEED_PAXG;
        t2Assets[5] = ALTS;  t2Weights[5] = 1_500; t2Feeds[5] = FEED_ALTS;
        registry.createTier(2, "High Risk", t2Assets, t2Weights, t2Feeds);

        factory = new VaultFactory(address(usdc), address(registry), feeRecipient);
    }

    // ─── Test 1: Multiple vaults per user ────────────────────────────────────

    function test_createVault_multiplePerUser() public {
        vm.startPrank(userA);

        address vault0 = factory.createVault(0, false);
        address vault1 = factory.createVault(1, false);
        address vault2 = factory.createVault(2, false);

        assertEq(factory.getUserVault(userA, 0), vault0, "Low vault mismatch");
        assertEq(factory.getUserVault(userA, 1), vault1, "Med vault mismatch");
        assertEq(factory.getUserVault(userA, 2), vault2, "High vault mismatch");

        (address[] memory vaults, uint8[] memory tiers) = factory.getUserVaults(userA);
        assertEq(vaults.length, 3, "Should have 3 vaults");
        assertEq(tiers.length, 3, "Should have 3 tiers");

        assertEq(factory.getVaultCount(), 3);

        vm.stopPrank();
    }

    function test_createVault_vaultsAreIsolated() public {
        vm.startPrank(userA);
        address vault0 = factory.createVault(0, false);
        address vault1 = factory.createVault(1, false);
        vm.stopPrank();

        assertTrue(vault0 != vault1, "Each tier must produce a distinct vault");
        assertEq(PortfolioVault(vault0).riskTier(), 0);
        assertEq(PortfolioVault(vault1).riskTier(), 1);
    }

    // ─── Test 2: Cannot create duplicate tier vault ───────────────────────────

    function test_createVault_revertOnDuplicateTier() public {
        vm.startPrank(userA);
        factory.createVault(0, false);

        vm.expectRevert(VaultFactory.TierVaultExists.selector);
        factory.createVault(0, false);
        vm.stopPrank();
    }

    function test_createVault_sameTierDifferentUsersAllowed() public {
        vm.prank(userA);
        address vaultA = factory.createVault(0, false);

        vm.prank(userB);
        address vaultB = factory.createVault(0, false);

        assertTrue(vaultA != vaultB, "Different users get distinct vaults");
    }

    // ─── Test 3: Deposit enforces receiver == msg.sender ─────────────────────

    function test_deposit_succeedsForSelf() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        uint256 shares = PortfolioVault(vault).deposit(amount, userA);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive non-zero shares");
        assertEq(PortfolioVault(vault).balanceOf(userA), shares);
    }

    function test_deposit_revertForThirdPartyReceiver() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        PortfolioVault(vault).deposit(amount, userB);
        vm.stopPrank();
    }

    // ─── Test 4: Withdraw enforces receiver == owner == msg.sender ───────────

    function test_withdraw_succeedsForSelf() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        uint256 balanceBefore = usdc.balanceOf(userA);
        PortfolioVault(vault).withdraw(amount, userA, userA);
        vm.stopPrank();

        assertEq(usdc.balanceOf(userA), balanceBefore + amount);
        assertEq(PortfolioVault(vault).balanceOf(userA), 0);
    }

    function test_withdraw_revertWhenReceiverIsThirdParty() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        PortfolioVault(vault).withdraw(amount, userB, userA);
        vm.stopPrank();
    }

    function test_withdraw_revertWhenOwnerIsThirdParty() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        PortfolioVault(vault).withdraw(amount, userA, userB);
        vm.stopPrank();
    }

    // ─── Test 5: Multiple users, multiple tiers ───────────────────────────────

    function test_multipleUsersMultipleTiers() public {
        // User A creates Low + High.
        vm.startPrank(userA);
        factory.createVault(0, false);
        factory.createVault(2, false);
        vm.stopPrank();

        // User B creates Medium only.
        vm.prank(userB);
        factory.createVault(1, false);

        (address[] memory vaultsA, uint8[] memory tiersA) = factory.getUserVaults(userA);
        assertEq(vaultsA.length, 2, "User A should have 2 vaults");
        assertEq(tiersA.length, 2);

        (address[] memory vaultsB, uint8[] memory tiersB) = factory.getUserVaults(userB);
        assertEq(vaultsB.length, 1, "User B should have 1 vault");
        assertEq(tiersB.length, 1);

        assertEq(factory.getVaultCount(), 3);

        // hasVault spot checks.
        assertTrue(factory.hasVault(userA, 0));
        assertFalse(factory.hasVault(userA, 1));
        assertTrue(factory.hasVault(userA, 2));
        assertFalse(factory.hasVault(userB, 0));
        assertTrue(factory.hasVault(userB, 1));
    }

    // ─── Test 6: Paginated getAllVaults ───────────────────────────────────────

    function test_getAllVaults_pagination() public {
        vm.prank(userA);
        factory.createVault(0, false);
        vm.prank(userA);
        factory.createVault(1, false);
        vm.prank(userB);
        factory.createVault(2, false);

        address[] memory page1 = factory.getAllVaults(0, 2);
        assertEq(page1.length, 2);

        address[] memory page2 = factory.getAllVaults(2, 10); // limit exceeds remaining
        assertEq(page2.length, 1);

        address[] memory all = factory.getAllVaults(0, 100);
        assertEq(all.length, 3);
    }

    // ─── Test 7: withdrawAll ─────────────────────────────────────────────────

    function test_withdrawAll_burnsAllShares() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 500e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        uint256 sharesBefore = PortfolioVault(vault).balanceOf(userA);
        assertGt(sharesBefore, 0);

        PortfolioVault(vault).withdrawAll();
        vm.stopPrank();

        assertEq(PortfolioVault(vault).balanceOf(userA), 0, "All shares should be burned");
        assertEq(usdc.balanceOf(userA), amount, "Full amount returned");
    }

    function test_withdrawAll_revertWhenNoShares() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        vm.prank(userA);
        vm.expectRevert(PortfolioVault.ZeroAmount.selector);
        PortfolioVault(vault).withdrawAll();
    }
}
