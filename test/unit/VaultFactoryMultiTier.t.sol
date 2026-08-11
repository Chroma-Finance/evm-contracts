// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
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

// ─── Mock Chainlink aggregator ($1 price) ─────────────────────────────────────

contract MockAggregator {
    uint80 public roundId = 1;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, 1e8, 0, block.timestamp, roundId);
    }
}

// ─── Mock SwapRouter ─────────────────────────────────────────────────────────
//
// Pulls inputToken from caller, mints tokensOut 1:1, so all tokens are valued
// equally at $1 (matching the MockAggregator price). Implements IChromaSwapRouter.

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

contract VaultFactoryMultiTierTest is Test {
    // Mirror EventNotifier.VaultCreated for vm.expectEmit
    event VaultCreated(address indexed user, address indexed vault, uint8 indexed tier, uint256 timestamp);

    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    MockSwapRouter   internal router;
    MockERC20        internal usdc;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal userA        = makeAddr("userA");
    address internal userB        = makeAddr("userB");

    // Real MockERC20 instances so swaps can mint to vaults.
    MockERC20 internal WBTC;
    MockERC20 internal WETH;
    MockERC20 internal XAUT;
    MockERC20 internal PAXG;
    MockERC20 internal STETH;
    MockERC20 internal ALTS;

    MockAggregator internal feedWbtc;
    MockAggregator internal feedWeth;
    MockAggregator internal feedXaut;
    MockAggregator internal feedPaxg;
    MockAggregator internal feedSteth;
    MockAggregator internal feedAlts;

    function setUp() public {
        usdc  = new MockERC20("USD Coin",  "USDC",  6);
        WBTC  = new MockERC20("Wrapped BTC",  "WBTC",  6);
        WETH  = new MockERC20("Wrapped ETH",  "WETH",  6);
        XAUT  = new MockERC20("Tether Gold",  "XAUT",  6);
        PAXG  = new MockERC20("PAX Gold",     "PAXG",  6);
        STETH = new MockERC20("Staked ETH",   "stETH", 6);
        ALTS  = new MockERC20("Alts Token",   "ALTS",  6);

        feedWbtc  = new MockAggregator();
        feedWeth  = new MockAggregator();
        feedXaut  = new MockAggregator();
        feedPaxg  = new MockAggregator();
        feedSteth = new MockAggregator();
        feedAlts  = new MockAggregator();

        registry = new RiskTierRegistry();
        router   = new MockSwapRouter();

        // Tier 0 — Low Risk: 40% WBTC | 30% XAUT | 30% PAXG
        {
            address[] memory t = new address[](3);
            uint256[] memory w = new uint256[](3);
            address[] memory f = new address[](3);
            t[0] = address(WBTC);  w[0] = 4_000;  f[0] = address(feedWbtc);
            t[1] = address(XAUT);  w[1] = 3_000;  f[1] = address(feedXaut);
            t[2] = address(PAXG);  w[2] = 3_000;  f[2] = address(feedPaxg);
            registry.createTier(0, "Low Risk", t, w, f);
        }

        // Tier 1 — Medium Risk
        {
            address[] memory t = new address[](5);
            uint256[] memory w = new uint256[](5);
            address[] memory f = new address[](5);
            t[0] = address(WBTC);  w[0] = 2_500;  f[0] = address(feedWbtc);
            t[1] = address(WETH);  w[1] = 2_500;  f[1] = address(feedWeth);
            t[2] = address(XAUT);  w[2] = 2_000;  f[2] = address(feedXaut);
            t[3] = address(PAXG);  w[3] = 2_000;  f[3] = address(feedPaxg);
            t[4] = address(STETH); w[4] = 1_000;  f[4] = address(feedSteth);
            registry.createTier(1, "Medium Risk", t, w, f);
        }

        // Tier 2 — High Risk
        {
            address[] memory t = new address[](6);
            uint256[] memory w = new uint256[](6);
            address[] memory f = new address[](6);
            t[0] = address(WBTC);  w[0] = 2_500;  f[0] = address(feedWbtc);
            t[1] = address(WETH);  w[1] = 2_500;  f[1] = address(feedWeth);
            t[2] = address(STETH); w[2] = 1_500;  f[2] = address(feedSteth);
            t[3] = address(XAUT);  w[3] = 1_000;  f[3] = address(feedXaut);
            t[4] = address(PAXG);  w[4] = 1_000;  f[4] = address(feedPaxg);
            t[5] = address(ALTS);  w[5] = 1_500;  f[5] = address(feedAlts);
            registry.createTier(2, "High Risk", t, w, f);
        }

        factory = new VaultFactory(address(router), address(registry), feeRecipient);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _deposit(address vaultAddr, address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(vaultAddr, amount);
        PortfolioVault(vaultAddr).deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── Vault creation registry ─────────────────────────────────────────────

    function test_createVault_multiplePerUser() public {
        vm.startPrank(userA);
        address vault0 = factory.createVault(0, false);
        address vault1 = factory.createVault(1, false);
        address vault2 = factory.createVault(2, false);
        vm.stopPrank();

        assertEq(factory.getUserVault(userA, 0), vault0);
        assertEq(factory.getUserVault(userA, 1), vault1);
        assertEq(factory.getUserVault(userA, 2), vault2);

        (address[] memory vaults, uint8[] memory tiers) = factory.getUserVaults(userA);
        assertEq(vaults.length, 3);
        assertEq(tiers.length, 3);
        assertEq(factory.getVaultCount(), 3);
    }

    function test_createVault_vaultsAreIsolated() public {
        vm.startPrank(userA);
        address vault0 = factory.createVault(0, false);
        address vault1 = factory.createVault(1, false);
        vm.stopPrank();

        assertTrue(vault0 != vault1);
        assertEq(PortfolioVault(vault0).riskTier(), 0);
        assertEq(PortfolioVault(vault1).riskTier(), 1);
    }

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

        assertTrue(vaultA != vaultB);
    }

    // ─── Deposit: only owner can deposit ─────────────────────────────────────

    function test_deposit_succeedsForOwner() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        _deposit(vault, userA, amount);

        assertGt(PortfolioVault(vault).balanceOf(userA), 0);
    }

    function test_deposit_revertForNonOwner() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        usdc.mint(userB, amount);
        vm.startPrank(userB);
        usdc.approve(vault, amount);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        PortfolioVault(vault).deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── Withdraw: only owner can withdraw ───────────────────────────────────

    function test_withdraw_succeedsForOwner() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        uint256 amount = 1_000e6;
        _deposit(vault, userA, amount);

        uint256 shares = PortfolioVault(vault).balanceOf(userA);
        assertGt(shares, 0);

        // Withdraw as portfolio tokens (outputToken = address(0))
        vm.prank(userA);
        PortfolioVault(vault).withdraw(address(0), shares, block.timestamp, new bytes(0));

        assertEq(PortfolioVault(vault).balanceOf(userA), 0);
    }

    function test_withdraw_revertForNonOwner() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        _deposit(vault, userA, 1_000e6);
        uint256 shares = PortfolioVault(vault).balanceOf(userA);

        vm.prank(userB);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        PortfolioVault(vault).withdraw(address(0), shares, block.timestamp, new bytes(0));
    }

    // ─── transferOwnership blocked ────────────────────────────────────────────

    function test_transferOwnership_reverts() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        vm.prank(userA);
        vm.expectRevert(PortfolioVault.OwnershipTransferBlocked.selector);
        PortfolioVault(vault).transferOwnership(userB);
    }

    // ─── Multiple users, multiple tiers ──────────────────────────────────────

    function test_multipleUsersMultipleTiers() public {
        vm.startPrank(userA);
        factory.createVault(0, false);
        factory.createVault(2, false);
        vm.stopPrank();

        vm.prank(userB);
        factory.createVault(1, false);

        (address[] memory vaultsA,) = factory.getUserVaults(userA);
        assertEq(vaultsA.length, 2);

        (address[] memory vaultsB,) = factory.getUserVaults(userB);
        assertEq(vaultsB.length, 1);

        assertEq(factory.getVaultCount(), 3);

        assertTrue(factory.hasVault(userA, 0));
        assertFalse(factory.hasVault(userA, 1));
        assertTrue(factory.hasVault(userA, 2));
        assertFalse(factory.hasVault(userB, 0));
        assertTrue(factory.hasVault(userB, 1));
    }

    // ─── Paginated getAllVaults ────────────────────────────────────────────────

    function test_getAllVaults_pagination() public {
        vm.prank(userA);
        factory.createVault(0, false);
        vm.prank(userA);
        factory.createVault(1, false);
        vm.prank(userB);
        factory.createVault(2, false);

        address[] memory page1 = factory.getAllVaults(0, 2);
        assertEq(page1.length, 2);

        address[] memory page2 = factory.getAllVaults(2, 10);
        assertEq(page2.length, 1);

        address[] memory all = factory.getAllVaults(0, 100);
        assertEq(all.length, 3);
    }

    // ─── Zero shares with no balance ─────────────────────────────────────────

    function test_withdraw_zeroShares_reverts() public {
        vm.prank(userA);
        address vault = factory.createVault(0, false);

        vm.prank(userA);
        vm.expectRevert(PortfolioVault.ZeroAmount.selector);
        PortfolioVault(vault).withdraw(address(0), 0, block.timestamp, new bytes(0));
    }

    // ─── Branch coverage additions ────────────────────────────────────────────

    function test_createVault_tierNotRegistered_reverts() public {
        vm.prank(userA);
        vm.expectRevert(RiskTierRegistry.TierNotFound.selector);
        factory.createVault(99, false);
    }

    function test_createVault_emitsVaultCreatedEvent() public {
        // Check user (topic1) and tier (topic3); vault address is unknown before creation.
        vm.expectEmit(true, false, true, false, factory.eventNotifier());
        emit VaultCreated(userA, address(0), 0, 0);

        vm.prank(userA);
        factory.createVault(0, false);
    }

    function test_getUserVault_returnsZeroForNonExistent() public {
        assertEq(factory.getUserVault(userA, 0), address(0));
    }

    function test_getAllVaults_emptyWhenNoVaults() public {
        address[] memory vaults = factory.getAllVaults(0, 100);
        assertEq(vaults.length, 0);
    }

    function test_swapRouter_addressStoredCorrectly() public {
        assertEq(factory.swapRouter(), address(router));
    }
}
