// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {EventNotifier} from "../../src/core/EventNotifier.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

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

contract EventNotifierTest is Test {
    // Mirror EventNotifier events so Forge can match them in expectEmit.
    event Deposited(address indexed user, address indexed vault, uint8 indexed tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets, uint256 timestamp);
    event Withdrawn(address indexed user, address indexed vault, uint8 indexed tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets, uint256 timestamp);
    event ManagementFeeAccrued(address indexed vault, uint8 indexed tier, uint256 feeShares, uint256 vaultTotalAssets, uint256 timestamp);
    event PerformanceFeeCharged(address indexed vault, uint8 indexed tier, address indexed user, uint256 feeAssets, uint256 vaultTotalAssets, uint256 timestamp);
    event VaultCreated(address indexed user, address indexed vault, uint8 indexed tier, uint256 timestamp);
    // Mirror ERC-4626 Deposit event from PortfolioVault.
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    EventNotifier    internal notifier;
    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    MockERC20        internal usdc;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal userA        = makeAddr("userA");
    address internal userB        = makeAddr("userB");
    address internal attacker     = makeAddr("attacker");

    address internal WBTC  = makeAddr("WBTC");
    address internal WETH  = makeAddr("WETH");
    address internal XAUT  = makeAddr("XAUT");
    address internal PAXG  = makeAddr("PAXG");
    address internal STETH = makeAddr("stETH");
    address internal ALTS  = makeAddr("ALTS");

    address internal FEED_WBTC  = makeAddr("feed_wbtc");
    address internal FEED_WETH  = makeAddr("feed_weth");
    address internal FEED_XAUT  = makeAddr("feed_xaut");
    address internal FEED_PAXG  = makeAddr("feed_paxg");
    address internal FEED_STETH = makeAddr("feed_steth");
    address internal FEED_ALTS  = makeAddr("feed_alts");

    function setUp() public {
        usdc     = new MockERC20();
        registry = new RiskTierRegistry();

        address[] memory t0Assets  = new address[](3);
        uint256[] memory t0Weights = new uint256[](3);
        address[] memory t0Feeds   = new address[](3);
        t0Assets[0] = WBTC;  t0Weights[0] = 4_000; t0Feeds[0] = FEED_WBTC;
        t0Assets[1] = XAUT;  t0Weights[1] = 3_000; t0Feeds[1] = FEED_XAUT;
        t0Assets[2] = PAXG;  t0Weights[2] = 3_000; t0Feeds[2] = FEED_PAXG;
        registry.createTier(0, "Low Risk", t0Assets, t0Weights, t0Feeds);

        address[] memory t1Assets  = new address[](5);
        uint256[] memory t1Weights = new uint256[](5);
        address[] memory t1Feeds   = new address[](5);
        t1Assets[0] = WBTC;  t1Weights[0] = 2_500; t1Feeds[0] = FEED_WBTC;
        t1Assets[1] = WETH;  t1Weights[1] = 2_500; t1Feeds[1] = FEED_WETH;
        t1Assets[2] = XAUT;  t1Weights[2] = 2_000; t1Feeds[2] = FEED_XAUT;
        t1Assets[3] = PAXG;  t1Weights[3] = 2_000; t1Feeds[3] = FEED_PAXG;
        t1Assets[4] = STETH; t1Weights[4] = 1_000; t1Feeds[4] = FEED_STETH;
        registry.createTier(1, "Medium Risk", t1Assets, t1Weights, t1Feeds);

        factory  = new VaultFactory(address(usdc), address(registry), feeRecipient);
        notifier = EventNotifier(factory.eventNotifier());
    }

    // ─── Access control unit tests ───────────────────────────────────────────

    function test_authorize_ownerCanAuthorize() public {
        address emitter = makeAddr("emitter");
        assertFalse(notifier.authorized(emitter));
        vm.prank(address(factory));
        notifier.authorize(emitter);
        assertTrue(notifier.authorized(emitter));
    }

    function test_authorize_revertZeroAddress() public {
        vm.prank(address(factory));
        vm.expectRevert(EventNotifier.ZeroAddress.selector);
        notifier.authorize(address(0));
    }

    function test_authorize_revertNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        notifier.authorize(attacker);
    }

    function test_revoke_ownerCanRevoke() public {
        address emitter = makeAddr("emitter");
        vm.prank(address(factory));
        notifier.authorize(emitter);
        assertTrue(notifier.authorized(emitter));

        vm.prank(address(factory));
        notifier.revoke(emitter);
        assertFalse(notifier.authorized(emitter));
    }

    function test_revoke_revertNonOwner() public {
        vm.prank(address(factory));
        notifier.authorize(makeAddr("emitter"));
        vm.prank(attacker);
        vm.expectRevert();
        notifier.revoke(makeAddr("emitter"));
    }

    function test_emitDeposit_revertUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(EventNotifier.Unauthorized.selector);
        notifier.emitDeposit(attacker, makeAddr("vault"), 0, 100, 100, 0);
    }

    function test_emitWithdrawal_revertUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(EventNotifier.Unauthorized.selector);
        notifier.emitWithdrawal(attacker, makeAddr("vault"), 0, 100, 100, 0);
    }

    function test_emitManagementFee_revertUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(EventNotifier.Unauthorized.selector);
        notifier.emitManagementFee(makeAddr("vault"), 0, 50, 0);
    }

    function test_emitPerformanceFee_revertUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(EventNotifier.Unauthorized.selector);
        notifier.emitPerformanceFee(makeAddr("vault"), 0, attacker, 10, 0);
    }

    function test_emitVaultCreated_revertUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(EventNotifier.Unauthorized.selector);
        notifier.emitVaultCreated(attacker, makeAddr("vault"), 0);
    }

    // ─── VaultFactory integration ────────────────────────────────────────────

    function test_factory_deploysEventNotifier() public view {
        assertTrue(factory.eventNotifier() != address(0), "EventNotifier not deployed");
    }

    function test_factory_ownedByFactory() public view {
        assertEq(notifier.owner(), address(factory), "EventNotifier owner should be factory");
    }

    function test_factory_selfAuthorized() public view {
        assertTrue(notifier.authorized(address(factory)), "Factory should be authorized");
    }

    function test_factory_authorizesVaultOnCreation() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);
        assertTrue(notifier.authorized(vault), "Vault should be authorized after creation");
    }

    function test_factory_emitsVaultCreatedViaNotifier() public {
        // Only check user (topic1) and tier (topic3); vault address (topic2) unknown before creation.
        vm.expectEmit(true, false, true, false, address(notifier));
        emit VaultCreated(userA, address(0), 0, 0);

        vm.prank(userA);
        factory.createVault(0, false);
    }

    function test_factory_multipleVaultsAllAuthorized() public {
        vm.prank(userA);
        address vaultA0 = factory.createVault(0, false);
        vm.prank(userA);
        address vaultA1 = factory.createVault(1, false);
        vm.prank(userB);
        address vaultB0 = factory.createVault(0, false);

        assertTrue(notifier.authorized(vaultA0));
        assertTrue(notifier.authorized(vaultA1));
        assertTrue(notifier.authorized(vaultB0));
    }

    // ─── Deposit event integration tests ─────────────────────────────────────

    function test_deposit_emitsDepositedViaNotifier() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);

        uint256 expectedShares = PortfolioVault(vault).previewDeposit(amount);

        // vaultTotalAssets = totalAssetsUSD(): USDC balance scaled from 6 dec to 8 dec ($1 fallback).
        vm.expectEmit(true, true, true, true, address(notifier));
        emit Deposited(userA, vault, 0, amount, expectedShares, amount * 100, block.timestamp);

        PortfolioVault(vault).deposit(amount, userA);
        vm.stopPrank();
    }

    function test_deposit_eventContainsCorrectTier() public {
        vm.prank(userA);
        address vault1 = factory.createVault(1, false);

        uint256 amount = 500e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault1, amount);

        uint256 expectedShares = PortfolioVault(vault1).previewDeposit(amount);

        vm.expectEmit(true, true, true, true, address(notifier));
        emit Deposited(userA, vault1, 1, amount, expectedShares, amount * 100, block.timestamp);

        PortfolioVault(vault1).deposit(amount, userA);
        vm.stopPrank();
    }

    // ─── Withdrawal event integration tests ──────────────────────────────────

    function test_withdraw_emitsWithdrawnViaNotifier() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        uint256 shares = PortfolioVault(vault).previewWithdraw(amount);

        vm.expectEmit(true, true, true, true, address(notifier));
        emit Withdrawn(userA, vault, 0, amount, shares, 0, block.timestamp);

        PortfolioVault(vault).withdraw(amount, userA, userA);
        vm.stopPrank();
    }

    function test_withdrawAll_emitsWithdrawnViaNotifier() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 500e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);
        PortfolioVault(vault).deposit(amount, userA);

        uint256 shares = PortfolioVault(vault).balanceOf(userA);
        uint256 assets = PortfolioVault(vault).previewRedeem(shares);

        vm.expectEmit(true, true, true, true, address(notifier));
        emit Withdrawn(userA, vault, 0, assets, shares, 0, block.timestamp);

        PortfolioVault(vault).withdrawAll();
        vm.stopPrank();
    }

    // ─── Multi-vault: all events route through single EventNotifier ──────────

    function test_multipleVaults_allEventsRouteThroughSingleNotifier() public {
        vm.prank(userA);
        address vaultLow = factory.createVault(0, false);
        vm.prank(userB);
        address vaultMed = factory.createVault(1, false);

        uint256 amountA = 1_000e6;
        uint256 amountB = 2_000e6;
        usdc.mint(userA, amountA);
        usdc.mint(userB, amountB);

        vm.startPrank(userA);
        usdc.approve(vaultLow, amountA);
        vm.expectEmit(true, true, true, false, address(notifier));
        emit Deposited(userA, vaultLow, 0, amountA, 0, 0, 0);
        PortfolioVault(vaultLow).deposit(amountA, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        usdc.approve(vaultMed, amountB);
        vm.expectEmit(true, true, true, false, address(notifier));
        emit Deposited(userB, vaultMed, 1, amountB, 0, 0, 0);
        PortfolioVault(vaultMed).deposit(amountB, userB);
        vm.stopPrank();
    }

    // ─── Verify ERC-4626 events are still emitted ────────────────────────────

    function test_deposit_stillEmitsERC4626DepositEvent() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userA, amount);

        vm.startPrank(userA);
        usdc.approve(vault, amount);

        uint256 expectedShares = PortfolioVault(vault).previewDeposit(amount);

        // ERC-4626 Deposit event still emitted from vault itself.
        vm.expectEmit(true, true, false, true, vault);
        emit Deposit(userA, userA, amount, expectedShares);

        PortfolioVault(vault).deposit(amount, userA);
        vm.stopPrank();
    }
}
