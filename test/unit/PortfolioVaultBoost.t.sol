// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {GuardianModule} from "../../src/modules/GuardianModule.sol";
import {ITierYieldRouter} from "../../src/interfaces/ITierYieldRouter.sol";

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

// ─── Mock TierYieldRouter: single-asset, 1:1 units, self-acting as its own strategy ──────────
//
// Collapses the real router -> strategy hop into one contract: strategyOf(asset) points at
// itself, and deposited tokens are held (and shares tracked) directly here rather than being
// forwarded on to a separate strategy contract. A real TierYieldRouter always forwards to a
// separate ISingleAssetYieldStrategy — see test/unit/TierYieldRouter.t.sol and
// test/unit/PortfolioVaultBoostRouter.t.sol for that two-hop wiring exercised directly. This
// mock only needs to satisfy PortfolioVault's ITierYieldRouter-shaped calls.

contract MockTierYieldRouter is ITierYieldRouter {
    address public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(address asset_) {
        asset = asset_;
    }

    function strategyOf(address asset_) external view returns (address) {
        return asset_ == asset ? address(this) : address(0);
    }

    function deposit(address asset_, uint256 amount) external {
        MockERC20(asset_).transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
        totalShares          += amount;
    }

    function withdrawAll(address asset_) external returns (uint256 amount) {
        uint256 shares = sharesOf[msg.sender];
        if (shares == 0 || totalShares == 0) return 0;

        uint256 bal = MockERC20(asset_).balanceOf(address(this));
        amount = (bal * shares) / totalShares;

        sharesOf[msg.sender] = 0;
        totalShares          -= shares;

        if (amount > 0) MockERC20(asset_).transfer(msg.sender, amount);
    }

    function valueOf(address vault, address asset_) external view returns (uint256) {
        if (asset_ != asset || totalShares == 0) return 0;
        uint256 bal = MockERC20(asset_).balanceOf(address(this));
        return (bal * sharesOf[vault]) / totalShares;
    }

    function registerVault(address) external {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract PortfolioVaultBoostTest is Test {
    event BoostEntered(address indexed owner, uint256[] amounts);
    event BoostExited(address indexed owner, uint256[] amounts);

    PortfolioVault     internal vault;
    MockERC20          internal usdc;
    MockERC20          internal foo;
    MockAggregator     internal fooFeed;
    MockSwapRouter      internal mockRouter;
    MockTierYieldRouter internal optimizer;
    GuardianModule      internal gm;

    uint256 internal guardianKey = 0xB0057;
    address internal guardian;

    address internal vaultOwner   = makeAddr("vaultOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal nonOwner     = makeAddr("nonOwner");

    bytes32 internal constant BOOST_APPROVAL_TYPEHASH = keccak256(
        "BoostApproval(address vault,address owner,uint256 nonce,uint256 deadline)"
    );

    uint256 constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 constant EXPECTED_USD   = 1_000e8;
    uint256 constant MIN_BOOST_USD  = 500e8;

    function setUp() public {
        usdc    = new MockERC20("USD Coin", "USDC", 6);
        foo     = new MockERC20("Foo",      "FOO",  6);
        fooFeed = new MockAggregator();
        mockRouter = new MockSwapRouter();
        gm      = new GuardianModule();
        guardian = vm.addr(guardianKey);

        optimizer = new MockTierYieldRouter(address(foo));

        vault = _newVault(address(optimizer), MIN_BOOST_USD, address(gm));
    }

    function _newVault(address optimizer_, uint256 minBoostUsd_, address guardianModule_)
        internal
        returns (PortfolioVault v)
    {
        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);

        v = new PortfolioVault();
        v.initialize(
            vaultOwner, 0, feeRecipient,
            address(0),          // eventNotifier — off for unit tests
            guardianModule_,
            address(0),          // recoveryModule
            address(mockRouter),
            optimizer_,
            minBoostUsd_,
            tokens, weights, feeds
        );
    }

    function _deposit(PortfolioVault v, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(vaultOwner, amount);
        vm.startPrank(vaultOwner);
        usdc.approve(address(v), amount);
        shares = v.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _signBoost(address vault_, address owner_, uint256 nonce_, uint256 deadline_)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(BOOST_APPROVAL_TYPEHASH, vault_, owner_, nonce_, deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gm.getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── enterBoost ──────────────────────────────────────────────────────────

    function test_enterBoost_noGuardian_autoApproves_succeeds() public {
        _deposit(vault, DEPOSIT_AMOUNT);

        vm.prank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        assertTrue(vault.boosted());
        assertEq(foo.balanceOf(address(vault)), 0);
        assertEq(foo.balanceOf(address(optimizer)), DEPOSIT_AMOUNT);
        assertEq(optimizer.sharesOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function test_enterBoost_emitsEvent() public {
        _deposit(vault, DEPOSIT_AMOUNT);

        uint256[] memory expected = new uint256[](1);
        expected[0] = DEPOSIT_AMOUNT;

        vm.expectEmit(true, false, false, true, address(vault));
        emit BoostEntered(vaultOwner, expected);

        vm.prank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));
    }

    function test_enterBoost_belowMinBoostAmountUsd_reverts() public {
        // Deposit less than MIN_BOOST_USD (500e8): deposit 100 USDC -> 100e8 USD.
        _deposit(vault, 100e6);

        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.BelowMinBoost.selector);
        vault.enterBoost(block.timestamp, new bytes(0));
    }

    function test_enterBoost_noOptimizer_reverts() public {
        PortfolioVault noBoost = _newVault(address(0), 0, address(0));
        _deposit(noBoost, DEPOSIT_AMOUNT);

        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.BoostNotAvailable.selector);
        noBoost.enterBoost(block.timestamp, new bytes(0));
    }

    function test_enterBoost_alreadyBoosted_reverts() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        vm.expectRevert(PortfolioVault.AlreadyBoosted.selector);
        vault.enterBoost(block.timestamp, new bytes(0));
        vm.stopPrank();
    }

    function test_enterBoost_nonOwner_reverts() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.prank(nonOwner);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        vault.enterBoost(block.timestamp, new bytes(0));
    }

    function test_enterBoost_withGuardian_noSignature_reverts() public {
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(vault, DEPOSIT_AMOUNT);

        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.BoostApprovalRequired.selector);
        vault.enterBoost(block.timestamp, new bytes(0));
    }

    function test_enterBoost_withGuardian_invalidSignature_reverts() public {
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(vault, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(BOOST_APPROVAL_TYPEHASH, address(vault), vaultOwner, uint256(0), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gm.getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.BoostApprovalRequired.selector);
        vault.enterBoost(deadline, badSig);
    }

    function test_enterBoost_withGuardian_validSignature_succeeds() public {
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(vault, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBoost(address(vault), vaultOwner, 0, deadline);

        vm.prank(vaultOwner);
        vault.enterBoost(deadline, sig);

        assertTrue(vault.boosted());
    }

    function test_enterBoost_withGuardian_replayPrevented() public {
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(vault, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBoost(address(vault), vaultOwner, 0, deadline);

        vm.prank(vaultOwner);
        vault.enterBoost(deadline, sig);

        vm.prank(vaultOwner);
        vault.exitBoost();

        // Same signature (nonce 0) must not be reusable for a second enterBoost.
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.BoostApprovalRequired.selector);
        vault.enterBoost(deadline, sig);
    }

    // ─── deposit/withdraw blocked while boosted ─────────────────────────────

    function test_deposit_whileBoosted_reverts() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        usdc.mint(vaultOwner, DEPOSIT_AMOUNT);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(PortfolioVault.VaultIsBoosted.selector);
        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_withdraw_whileBoosted_reverts() public {
        uint256 shares = _deposit(vault, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        vm.expectRevert(PortfolioVault.VaultIsBoosted.selector);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));
        vm.stopPrank();
    }

    // ─── exitBoost ───────────────────────────────────────────────────────────

    function test_exitBoost_succeeds_restoresBoostedFalseAndBalances() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));
        vault.exitBoost();
        vm.stopPrank();

        assertFalse(vault.boosted());
        assertEq(foo.balanceOf(address(vault)), DEPOSIT_AMOUNT);
        assertEq(foo.balanceOf(address(optimizer)), 0);
    }

    function test_exitBoost_emitsEvent() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.prank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        uint256[] memory expected = new uint256[](1);
        expected[0] = DEPOSIT_AMOUNT;

        vm.expectEmit(true, false, false, true, address(vault));
        emit BoostExited(vaultOwner, expected);

        vm.prank(vaultOwner);
        vault.exitBoost();
    }

    function test_exitBoost_notBoosted_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.NotBoosted.selector);
        vault.exitBoost();
    }

    function test_exitBoost_nonOwner_reverts() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.prank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        vm.prank(nonOwner);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        vault.exitBoost();
    }

    function test_exitBoost_requiresNoGuardianSignature() public {
        // Guardian is set (would gate enterBoost) but exitBoost() takes no deadline/signature
        // params at all — it is ungated by design, unlike enterBoost.
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(vault, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBoost(address(vault), vaultOwner, 0, deadline);
        vm.prank(vaultOwner);
        vault.enterBoost(deadline, sig);

        vm.prank(vaultOwner);
        vault.exitBoost(); // no signature args exist on this function; must not revert

        assertFalse(vault.boosted());
    }

    function test_deposit_afterExitBoost_succeeds() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));
        vault.exitBoost();
        vm.stopPrank();

        // Deposit works normally again once un-boosted.
        uint256 shares = _deposit(vault, DEPOSIT_AMOUNT);
        assertGt(shares, 0);
    }

    // ─── totalAssets while boosted ───────────────────────────────────────────

    function test_totalAssets_whileBoosted_matchesPreBoostValue() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        uint256 preBoostValue = vault.totalAssets();

        vm.prank(vaultOwner);
        vault.enterBoost(block.timestamp, new bytes(0));

        assertEq(vault.totalAssets(), preBoostValue);
        assertEq(vault.totalAssets(), EXPECTED_USD);
    }

    function test_totalAssets_notBoosted_usesDirectPortfolioValue() public {
        _deposit(vault, DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), EXPECTED_USD);
        assertFalse(vault.boosted());
    }
}
