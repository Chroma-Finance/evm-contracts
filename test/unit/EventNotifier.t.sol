// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {EventNotifier} from "../../src/core/EventNotifier.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";
import {IChromaSwapRouter} from "../../src/interfaces/ISwapRouter.sol";

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

    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }

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

// ─── Mock Chainlink aggregator ($1 price) ────────────────────────────────────

contract MockAggregator {
    uint80 public roundId = 1;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, 1e8, 0, block.timestamp, roundId);
    }
}

// ─── Mock SwapRouter ──────────────────────────────────────────────────────────

contract MockSwapRouter is IChromaSwapRouter {
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

// ─── Tests ───────────────────────────────────────────────────────────────────

contract EventNotifierTest is Test {
    // Mirror EventNotifier events for vm.expectEmit
    event Deposited(address indexed user, address indexed vault, uint8 indexed tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets, uint256 timestamp);
    event Withdrawn(address indexed user, address indexed vault, uint8 indexed tier, uint256 assets, uint256 shares, uint256 vaultTotalAssets, uint256 timestamp);
    event ManagementFeeAccrued(address indexed vault, uint8 indexed tier, uint256 feeShares, uint256 vaultTotalAssets, uint256 timestamp);
    event PerformanceFeeCharged(address indexed vault, uint8 indexed tier, address indexed user, uint256 feeAssets, uint256 vaultTotalAssets, uint256 timestamp);
    event VaultCreated(address indexed user, address indexed vault, uint8 indexed tier, uint256 timestamp);
    // Mirror vault Deposit event (not ERC-4626; vault uses owner + inputToken)
    event Deposit(address indexed owner, address indexed inputToken, uint256 amount, uint256 shares);

    EventNotifier    internal notifier;
    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    MockSwapRouter   internal router;
    MockERC20        internal usdc;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal userA        = makeAddr("userA");
    address internal userB        = makeAddr("userB");
    address internal attacker     = makeAddr("attacker");

    // Real MockERC20 portfolio tokens so totalAssets() resolves correctly.
    MockERC20 internal WBTC;
    MockERC20 internal WETH;
    MockERC20 internal XAUT;
    MockERC20 internal PAXG;
    MockERC20 internal STETH;

    MockAggregator internal feedWbtc;
    MockAggregator internal feedWeth;
    MockAggregator internal feedXaut;
    MockAggregator internal feedPaxg;
    MockAggregator internal feedSteth;

    function setUp() public {
        usdc  = new MockERC20("USD Coin", "USDC", 6);
        WBTC  = new MockERC20("Wrapped BTC",  "WBTC",  6);
        WETH  = new MockERC20("Wrapped ETH",  "WETH",  6);
        XAUT  = new MockERC20("Tether Gold",  "XAUT",  6);
        PAXG  = new MockERC20("PAX Gold",     "PAXG",  6);
        STETH = new MockERC20("Staked ETH",   "stETH", 6);

        feedWbtc  = new MockAggregator();
        feedWeth  = new MockAggregator();
        feedXaut  = new MockAggregator();
        feedPaxg  = new MockAggregator();
        feedSteth = new MockAggregator();

        router   = new MockSwapRouter();
        registry = new RiskTierRegistry();

        // Tier 0 — Low Risk: 40% WBTC | 30% XAUT | 30% PAXG
        {
            address[] memory t = new address[](3);
            uint256[] memory w = new uint256[](3);
            address[] memory f = new address[](3);
            t[0] = address(WBTC);  w[0] = 4_000; f[0] = address(feedWbtc);
            t[1] = address(XAUT);  w[1] = 3_000; f[1] = address(feedXaut);
            t[2] = address(PAXG);  w[2] = 3_000; f[2] = address(feedPaxg);
            registry.createTier(0, "Low Risk", t, w, f);
        }

        // Tier 1 — Medium Risk: 25% WBTC | 25% WETH | 20% XAUT | 20% PAXG | 10% STETH
        {
            address[] memory t = new address[](5);
            uint256[] memory w = new uint256[](5);
            address[] memory f = new address[](5);
            t[0] = address(WBTC);  w[0] = 2_500; f[0] = address(feedWbtc);
            t[1] = address(WETH);  w[1] = 2_500; f[1] = address(feedWeth);
            t[2] = address(XAUT);  w[2] = 2_000; f[2] = address(feedXaut);
            t[3] = address(PAXG);  w[3] = 2_000; f[3] = address(feedPaxg);
            t[4] = address(STETH); w[4] = 1_000; f[4] = address(feedSteth);
            registry.createTier(1, "Medium Risk", t, w, f);
        }

        factory  = new VaultFactory(address(router), address(registry), feeRecipient);
        notifier = EventNotifier(factory.eventNotifier());
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _deposit(address vaultAddr, address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(vaultAddr, amount);
        PortfolioVault(vaultAddr).deposit(address(usdc), amount);
        vm.stopPrank();
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
        assertTrue(factory.eventNotifier() != address(0));
    }

    function test_factory_ownedByFactory() public view {
        assertEq(notifier.owner(), address(factory));
    }

    function test_factory_selfAuthorized() public view {
        assertTrue(notifier.authorized(address(factory)));
    }

    function test_factory_authorizesVaultOnCreation() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);
        assertTrue(notifier.authorized(vault));
    }

    function test_factory_emitsVaultCreatedViaNotifier() public {
        // Only check user (topic1) and tier (topic3); vault address unknown before creation.
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

    // ─── Deposit event integration ───────────────────────────────────────────
    //
    // All portfolio tokens priced at $1 with 6 decimals:
    //   1 token = 1e6 units; value = (1e6 * 1e8) / 1e6 = 1e8 = $1 (8-dec).
    // 1000e6 USDC → 1000 tokens worth $1 each → totalAssets = 1000e8.

    function test_deposit_emitsDepositedViaNotifier() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount          = 1_000e6;
        uint256 expectedUsdIn   = 1_000e8; // $1000 in 8-dec
        uint256 expectedShares  = 1_000e8; // first deposit: shares = usdIn

        usdc.mint(userA, amount);
        vm.startPrank(userA);
        usdc.approve(vault, amount);

        vm.expectEmit(true, true, true, true, address(notifier));
        emit Deposited(userA, vault, 0, expectedUsdIn, expectedShares, expectedUsdIn, block.timestamp);

        PortfolioVault(vault).deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function test_deposit_eventContainsCorrectTier() public {
        vm.prank(userA);
        address vault1 = factory.createVault(1, false);

        uint256 amount         = 500e6;
        uint256 expectedUsdIn  = 500e8;
        uint256 expectedShares = 500e8;

        usdc.mint(userA, amount);
        vm.startPrank(userA);
        usdc.approve(vault1, amount);

        vm.expectEmit(true, true, true, true, address(notifier));
        emit Deposited(userA, vault1, 1, expectedUsdIn, expectedShares, expectedUsdIn, block.timestamp);

        PortfolioVault(vault1).deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── Withdrawal event integration ────────────────────────────────────────

    function test_withdraw_emitsWithdrawnViaNotifier() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        _deposit(vault, userA, 1_000e6);
        uint256 shares = PortfolioVault(vault).balanceOf(userA); // = 1000e8

        // usdValue = shares * (totalAssets+1)/(supply+1) ≈ shares for equal supply
        uint256 expectedUsdValue  = 1_000e8;
        uint256 expectedPostAssets = 0; // all portfolio tokens transferred out

        vm.startPrank(userA);
        vm.expectEmit(true, true, true, true, address(notifier));
        emit Withdrawn(userA, vault, 0, expectedUsdValue, shares, expectedPostAssets, block.timestamp);

        // outputToken = address(0) → direct portfolio token withdrawal; no guardian set → auto-approve
        PortfolioVault(vault).withdraw(address(0), shares, block.timestamp, new bytes(0));
        vm.stopPrank();
    }

    // ─── Multi-vault: all events route through single EventNotifier ──────────

    function test_multipleVaults_allEventsRouteThroughSingleNotifier() public {
        vm.prank(userA);
        address vaultLow = factory.createVault(0, false);
        vm.prank(userB);
        address vaultMed = factory.createVault(1, false);

        usdc.mint(userA, 1_000e6);
        usdc.mint(userB, 2_000e6);

        vm.startPrank(userA);
        usdc.approve(vaultLow, 1_000e6);
        vm.expectEmit(true, true, true, false, address(notifier));
        emit Deposited(userA, vaultLow, 0, 0, 0, 0, 0);
        PortfolioVault(vaultLow).deposit(address(usdc), 1_000e6);
        vm.stopPrank();

        vm.startPrank(userB);
        usdc.approve(vaultMed, 2_000e6);
        vm.expectEmit(true, true, true, false, address(notifier));
        emit Deposited(userB, vaultMed, 1, 0, 0, 0, 0);
        PortfolioVault(vaultMed).deposit(address(usdc), 2_000e6);
        vm.stopPrank();
    }

    // ─── Vault-level Deposit event ───────────────────────────────────────────

    function test_deposit_emitsVaultDepositEvent() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount         = 1_000e6;
        uint256 expectedShares = 1_000e8;

        usdc.mint(userA, amount);
        vm.startPrank(userA);
        usdc.approve(vault, amount);

        vm.expectEmit(true, true, false, true, vault);
        emit Deposit(userA, address(usdc), amount, expectedShares);

        PortfolioVault(vault).deposit(address(usdc), amount);
        vm.stopPrank();
    }
}
