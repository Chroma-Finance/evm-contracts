// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";

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

// ─── Tests ────────────────────────────────────────────────────────────────────

contract PortfolioVaultTest is Test {
    // Mirror vault events for vm.expectEmit
    event Deposit(address indexed owner, address indexed inputToken, uint256 amount, uint256 shares);
    event Withdraw(address indexed owner, address indexed outputToken, uint256 shares, uint256 usdValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    PortfolioVault internal vault;
    MockERC20      internal usdc;  // deposit input token (not a portfolio token)
    MockERC20      internal foo;   // sole portfolio token, 6 dec, $1
    MockERC20      internal bar;   // second token for multi-asset tests
    MockAggregator internal fooFeed;
    MockAggregator internal barFeed;
    MockSwapRouter internal mockRouter;

    address internal vaultOwner   = makeAddr("vaultOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal nonOwner     = makeAddr("nonOwner");

    // Deposit 1000e6 USDC → 1000e6 FOO (6 dec, $1) → totalAssets = 1000e8 (USD 8-dec)
    uint256 constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 constant EXPECTED_USD   = 1_000e8;
    uint256 constant EXPECTED_SHARES = 1_000e8;

    function setUp() public {
        usdc      = new MockERC20("USD Coin", "USDC", 6);
        foo       = new MockERC20("Foo",      "FOO",  6);
        bar       = new MockERC20("Bar",      "BAR",  6);
        fooFeed   = new MockAggregator();
        barFeed   = new MockAggregator();
        mockRouter = new MockSwapRouter();

        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);

        vault = new PortfolioVault();
        vault.initialize(
            vaultOwner, 0, feeRecipient,
            address(0),          // eventNotifier  — off for unit tests
            address(0),          // guardianModule — auto-approve
            address(0),          // recoveryModule
            address(mockRouter),
            tokens, weights, feeds
        );
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        usdc.mint(vaultOwner, amount);
        vm.startPrank(vaultOwner);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── initialize ──────────────────────────────────────────────────────────

    function test_initialize_alreadyInitialized_reverts() public {
        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);

        vm.expectRevert(PortfolioVault.AlreadyInitialized.selector);
        vault.initialize(vaultOwner, 0, feeRecipient, address(0), address(0), address(0),
                         address(mockRouter), tokens, weights, feeds);
    }

    function test_initialize_zeroOwner_reverts() public {
        PortfolioVault v2 = new PortfolioVault();
        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);

        vm.expectRevert(PortfolioVault.ZeroAddress.selector);
        v2.initialize(address(0), 0, feeRecipient, address(0), address(0), address(0),
                      address(mockRouter), tokens, weights, feeds);
    }

    function test_initialize_invalidWeightSum_reverts() public {
        PortfolioVault v2 = new PortfolioVault();
        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 5_000; feeds[0] = address(fooFeed); // not 10000

        vm.expectRevert(PortfolioVault.InvalidWeights.selector);
        v2.initialize(vaultOwner, 0, feeRecipient, address(0), address(0), address(0),
                      address(mockRouter), tokens, weights, feeds);
    }

    function test_initialize_setsRiskTierAndOwner() public view {
        assertEq(vault.riskTier(), 0);
        assertEq(vault.vaultOwner(), vaultOwner);
        assertEq(vault.owner(), vaultOwner);
    }

    // ─── deposit ─────────────────────────────────────────────────────────────

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0);
    }

    function test_deposit_zeroInputToken_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.ZeroAddress.selector);
        vault.deposit(address(0), DEPOSIT_AMOUNT);
    }

    function test_deposit_noRouter_reverts() public {
        PortfolioVault noRouter = new PortfolioVault();
        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);
        noRouter.initialize(vaultOwner, 0, feeRecipient, address(0), address(0), address(0),
                            address(0), // no router
                            tokens, weights, feeds);

        usdc.mint(vaultOwner, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        usdc.approve(address(noRouter), DEPOSIT_AMOUNT);
        vm.expectRevert(PortfolioVault.SwapRouterRequired.selector);
        noRouter.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_deposit_nonOwner_reverts() public {
        usdc.mint(nonOwner, DEPOSIT_AMOUNT);
        vm.startPrank(nonOwner);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_deposit_mintsCorrectShares() public {
        // First deposit: preUsd=0, postUsd=EXPECTED_USD
        // shares = EXPECTED_USD * (0+1) / (0+1) = EXPECTED_USD
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        assertEq(shares, EXPECTED_SHARES);
        assertEq(vault.balanceOf(vaultOwner), EXPECTED_SHARES);
    }

    function test_deposit_portfolioTokensHeldInVault() public {
        _deposit(DEPOSIT_AMOUNT);
        // All 1000e6 USDC swapped 1:1 to 1000e6 FOO (100% weight)
        assertEq(foo.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function test_deposit_multipleDeposits_equalSharesForEqualAmounts() public {
        uint256 shares1 = _deposit(DEPOSIT_AMOUNT);
        // Second deposit: preUsd=EXPECTED_USD, supply=EXPECTED_SHARES
        // usdIn = EXPECTED_USD; shares = EXPECTED_USD * (EXPECTED_SHARES+1)/(EXPECTED_USD+1) = EXPECTED_SHARES
        uint256 shares2 = _deposit(DEPOSIT_AMOUNT);
        assertEq(shares1, shares2);
    }

    function test_deposit_totalAssetsGrowsAfterDeposit() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), EXPECTED_USD);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(vaultOwner, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposit(vaultOwner, address(usdc), DEPOSIT_AMOUNT, EXPECTED_SHARES);

        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ─── withdraw ────────────────────────────────────────────────────────────

    function test_withdraw_zeroShares_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.ZeroAmount.selector);
        vault.withdraw(address(0), 0, block.timestamp, new bytes(0));
    }

    function test_withdraw_exceedsBalance_reverts() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.ExceedsMax.selector);
        vault.withdraw(address(0), shares + 1, block.timestamp, new bytes(0));
    }

    function test_withdraw_nonOwner_reverts() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);
        vm.prank(nonOwner);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));
    }

    function test_withdraw_directPortfolio_transfersFooToOwner() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));

        assertEq(vault.balanceOf(vaultOwner), 0);
        assertEq(foo.balanceOf(vaultOwner), DEPOSIT_AMOUNT); // 1000e6 FOO returned
    }

    function test_withdraw_directPortfolio_totalAssetsZeroAfter() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));

        assertEq(vault.totalAssets(), 0);
    }

    function test_withdraw_outputToken_swapsAndTransfersUsdc() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        uint256 usdValue = vault.withdraw(address(usdc), shares, block.timestamp, new bytes(0));

        assertEq(vault.balanceOf(vaultOwner), 0);
        assertEq(usdc.balanceOf(vaultOwner), DEPOSIT_AMOUNT); // 1:1 swap via mock router
        assertEq(usdValue, EXPECTED_USD);
    }

    function test_withdraw_noGuardian_autoApproves() public {
        // guardianModule = address(0) → skip validation; empty sig is fine
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0)); // must not revert
    }

    function test_withdraw_emitsEvent() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.startPrank(vaultOwner);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdraw(vaultOwner, address(0), shares, EXPECTED_USD);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));
        vm.stopPrank();
    }

    function test_withdraw_partialShares_burnsSomeSharesAndTransfersProRata() public {
        _deposit(DEPOSIT_AMOUNT); // 1000e8 shares
        uint256 half = EXPECTED_SHARES / 2;

        vm.prank(vaultOwner);
        vault.withdraw(address(0), half, block.timestamp, new bytes(0));

        assertEq(vault.balanceOf(vaultOwner), EXPECTED_SHARES - half);
        assertEq(foo.balanceOf(vaultOwner), DEPOSIT_AMOUNT / 2);
    }

    // ─── transferOwnership ───────────────────────────────────────────────────

    function test_transferOwnership_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(PortfolioVault.OwnershipTransferBlocked.selector);
        vault.transferOwnership(nonOwner);
    }

    function test_transferOwnershipFromRecovery_nonRecovery_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(PortfolioVault.Unauthorized.selector);
        vault.transferOwnershipFromRecovery(nonOwner);
    }

    function test_transferOwnershipFromRecovery_byRecovery_succeeds() public {
        address recoveryMod = makeAddr("recoveryModule");
        PortfolioVault v2   = new PortfolioVault();

        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);
        v2.initialize(vaultOwner, 0, feeRecipient, address(0), address(0), recoveryMod,
                      address(mockRouter), tokens, weights, feeds);

        address newOwner = makeAddr("newOwner");
        vm.prank(recoveryMod);
        v2.transferOwnershipFromRecovery(newOwner);

        assertEq(v2.owner(), newOwner);
        assertEq(v2.vaultOwner(), newOwner);
    }

    function test_transferOwnershipFromRecovery_zeroNewOwner_reverts() public {
        address recoveryMod = makeAddr("recoveryModule");
        PortfolioVault v2   = new PortfolioVault();

        address[] memory tokens  = new address[](1);
        uint256[] memory weights = new uint256[](1);
        address[] memory feeds   = new address[](1);
        tokens[0] = address(foo); weights[0] = 10_000; feeds[0] = address(fooFeed);
        v2.initialize(vaultOwner, 0, feeRecipient, address(0), address(0), recoveryMod,
                      address(mockRouter), tokens, weights, feeds);

        vm.prank(recoveryMod);
        vm.expectRevert(PortfolioVault.ZeroAddress.selector);
        v2.transferOwnershipFromRecovery(address(0));
    }

    // ─── previewDirectWithdrawal ──────────────────────────────────────────────

    function test_previewDirectWithdrawal_noShares_returnsEmpty() public view {
        (address[] memory tokens, uint256[] memory amounts) = vault.previewDirectWithdrawal(vaultOwner);
        assertEq(tokens.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_previewDirectWithdrawal_returnsProportionalAmounts() public {
        _deposit(DEPOSIT_AMOUNT);

        (address[] memory tokens, uint256[] memory amounts) = vault.previewDirectWithdrawal(vaultOwner);

        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(foo));
        assertEq(amounts[0], DEPOSIT_AMOUNT); // 100% of FOO held
    }

    function test_previewDirectWithdrawal_matchesActualWithdrawal() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        (address[] memory tokens, uint256[] memory amounts) = vault.previewDirectWithdrawal(vaultOwner);

        vm.prank(vaultOwner);
        vault.withdraw(address(0), shares, block.timestamp, new bytes(0));

        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(MockERC20(tokens[i]).balanceOf(vaultOwner), amounts[i]);
        }
    }

    function test_previewDirectWithdrawal_twoDepositors_proRata() public {
        // Two-token vault: FOO (50%) + BAR (50%)
        PortfolioVault v2 = new PortfolioVault();
        address[] memory tokens  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        tokens[0] = address(foo); weights[0] = 5_000; feeds[0] = address(fooFeed);
        tokens[1] = address(bar); weights[1] = 5_000; feeds[1] = address(barFeed);
        v2.initialize(vaultOwner, 1, feeRecipient, address(0), address(0), address(0),
                      address(mockRouter), tokens, weights, feeds);

        // Deposit 1000e6: 500e6 FOO + 500e6 BAR
        usdc.mint(vaultOwner, DEPOSIT_AMOUNT);
        vm.startPrank(vaultOwner);
        usdc.approve(address(v2), DEPOSIT_AMOUNT);
        v2.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();

        (address[] memory previewTokens, uint256[] memory previewAmounts) = v2.previewDirectWithdrawal(vaultOwner);
        assertEq(previewTokens.length, 2);
        assertEq(previewAmounts[0], 500e6); // 50% FOO
        assertEq(previewAmounts[1], 500e6); // 50% BAR
    }

    // ─── getTokenPrice ────────────────────────────────────────────────────────

    function test_getTokenPrice_noPriceFeed_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PortfolioVault.NoPriceFeed.selector, address(usdc)));
        vault.getTokenPrice(address(usdc));
    }

    function test_getTokenPrice_returnsOneUsd() public view {
        uint256 price = vault.getTokenPrice(address(foo));
        assertEq(price, 1e8); // $1 in 8-dec
    }

    // ─── ERC-20 share token ───────────────────────────────────────────────────

    function test_erc20_nameAndSymbol() public view {
        assertEq(vault.name(),   "Chroma Low Risk Vault");
        assertEq(vault.symbol(), "CV-LOW");
        assertEq(vault.decimals(), 18);
    }

    function test_erc20_transfer() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        vault.transfer(nonOwner, shares / 2);

        assertEq(vault.balanceOf(nonOwner), shares / 2);
        assertEq(vault.balanceOf(vaultOwner), shares - shares / 2);
    }

    function test_erc20_approveAndTransferFrom() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(vaultOwner);

        vm.prank(vaultOwner);
        vault.approve(nonOwner, shares);

        vm.prank(nonOwner);
        vault.transferFrom(vaultOwner, nonOwner, shares);

        assertEq(vault.balanceOf(nonOwner), shares);
        assertEq(vault.balanceOf(vaultOwner), 0);
    }
}
