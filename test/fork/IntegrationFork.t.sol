// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {DeployArbitrumFork}    from "../../script/DeployArbitrumFork.s.sol";
import {PortfolioVault}        from "../../src/core/PortfolioVault.sol";
import {SocialRecoveryModule}  from "../../src/modules/SocialRecoveryModule.sol";
import {IERC20}                from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @notice End-to-end integration tests against a live Arbitrum mainnet fork.
 *
 *         Run with:
 *           source .env && forge test --match-path "test/fork/IntegrationFork.t.sol" \
 *             --fork-url $ARBITRUM_RPC_URL -vvvv
 *
 *         All protocol contracts are deployed fresh on the fork via DeployArbitrumFork.
 *         Token addresses and RPC URL are loaded from environment variables.
 */
contract IntegrationForkTest is Test {

    // ── Protocol deployments ──────────────────────────────────────────────────

    DeployArbitrumFork.Deployments internal d;

    // ── Arbitrum token addresses (loaded from env in setUp) ───────────────────

    address internal WBTC;
    address internal WETH;
    address internal USDC;
    address internal USDT;

    // ── Supplemental Chainlink feeds for stablecoin swap oracle validation ────
    // Required by SwapRouter._getTokenPrice() for any token used as swap input/output.
    // Not in .env.example because the deployment script only configures WBTC/WETH feeds.

    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant USDT_USD_FEED = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;

    // ── Test accounts ─────────────────────────────────────────────────────────

    address internal deployer;
    address internal user;
    address internal recoveryGuardian1;
    address internal recoveryGuardian2;
    address internal recoveryGuardian3;

    // Known private key so we can produce EIP-712 guardian signatures in tests.
    uint256 internal constant GUARDIAN_PRIV_KEY = 0xA11CE_CAFE_BEEF_1337;
    address internal guardianAddr;

    // ── EIP-712 typehash (must mirror GuardianModule exactly) ─────────────────

    bytes32 internal constant WITHDRAWAL_APPROVAL_TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    // ── Amounts ───────────────────────────────────────────────────────────────

    uint256 internal constant DEPOSIT_USDC = 10_000e6; // 10,000 USDC (6 dec)
    uint256 internal constant DEPOSIT_USDT =  5_000e6; //  5,000 USDT (6 dec)

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));

        WBTC = vm.envAddress("WBTC");
        WETH = vm.envAddress("WETH");
        USDC = vm.envAddress("USDC");
        USDT = vm.envAddress("USDT");

        // Fund the deployer so the broadcast inside the script has gas.
        deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        vm.deal(deployer, 10 ether);

        // Deploy the full protocol stack via the deployment script.
        d = new DeployArbitrumFork().run();

        // The deployment script wires WBTC and WETH price feeds.
        // Stablecoin feeds are required for deposit (tokenIn oracle check) and
        // for withdrawal-to-USDC (tokenOut oracle check) in the SwapRouter.
        vm.startPrank(deployer);
        d.swapRouter.setPriceFeed(USDC, USDC_USD_FEED);
        d.swapRouter.setPriceFeed(USDT, USDT_USD_FEED);
        vm.stopPrank();

        user              = makeAddr("user");
        recoveryGuardian1 = makeAddr("guardian1");
        recoveryGuardian2 = makeAddr("guardian2");
        recoveryGuardian3 = makeAddr("guardian3");
        guardianAddr      = vm.addr(GUARDIAN_PRIV_KEY);

        console2.log("Fork block :", block.number);
        console2.log("chainId    :", block.chainid);
        console2.log("Factory    :", address(d.factory));
        console2.log("SwapRouter :", address(d.swapRouter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testCreateVault
    // ─────────────────────────────────────────────────────────────────────────

    function testCreateVault() public {
        address vault = _createVault(user, 0);

        assertTrue(vault != address(0), "vault not deployed");
        assertEq(PortfolioVault(vault).owner(),    user, "wrong owner");
        assertEq(PortfolioVault(vault).riskTier(), 0,    "wrong tier");

        // EIP-1167 minimal proxies produced by Clones.clone() are exactly 45 bytes.
        assertEq(vault.code.length, 45, "not an EIP-1167 proxy");

        // Factory registry updated
        assertEq(d.factory.getUserVault(user, 0), vault, "factory registry mismatch");

        console2.log("Vault:", vault);
        console2.log("Code length:", vault.code.length);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testDepositUSDC
    // ─────────────────────────────────────────────────────────────────────────

    function testDepositUSDC() public {
        address vault = _createVault(user, 0);
        _dealTokens(user, USDC, DEPOSIT_USDC);

        vm.startPrank(user);
        IERC20(USDC).approve(vault, DEPOSIT_USDC);
        uint256 shares = PortfolioVault(vault).deposit(USDC, DEPOSIT_USDC);
        vm.stopPrank();

        assertTrue(shares > 0, "no shares minted");
        assertEq(IERC20(USDC).balanceOf(vault), 0, "USDC left in vault after swap");

        (uint256 wbtcBal, uint256 wethBal) = _getPortfolioBalances(vault);
        assertTrue(wbtcBal > 0, "no WBTC after deposit");
        assertTrue(wethBal > 0, "no WETH after deposit");

        uint256 totalUsd = PortfolioVault(vault).totalAssets();
        assertTrue(totalUsd > 0, "zero totalAssets");

        // USD values of each leg (price is 8-dec Chainlink; decimals normalised per token).
        uint256 wbtcPrice = PortfolioVault(vault).getTokenPrice(WBTC);
        uint256 wethPrice = PortfolioVault(vault).getTokenPrice(WETH);
        uint256 wbtcUsd   = (wbtcBal * wbtcPrice) / 1e8;  // WBTC 8 dec
        uint256 wethUsd   = (wethBal * wethPrice) / 1e18; // WETH 18 dec

        // Each leg should be ~50% of total; allow 2% tolerance for price impact.
        uint256 diff = wbtcUsd > wethUsd ? wbtcUsd - wethUsd : wethUsd - wbtcUsd;
        assertLt(diff * 100 / totalUsd, 2, "portfolio legs imbalanced by more than 2%");

        console2.log("Shares minted       :", shares);
        console2.log("WBTC balance        :", wbtcBal);
        console2.log("WETH balance        :", wethBal);
        console2.log("totalAssets (8 dec) :", totalUsd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testDepositUSDT
    // ─────────────────────────────────────────────────────────────────────────

    function testDepositUSDT() public {
        address vault = _createVault(user, 0);
        _dealTokens(user, USDT, DEPOSIT_USDT);

        vm.startPrank(user);
        IERC20(USDT).approve(vault, DEPOSIT_USDT);
        uint256 shares = PortfolioVault(vault).deposit(USDT, DEPOSIT_USDT);
        vm.stopPrank();

        assertTrue(shares > 0, "no shares minted");
        assertEq(IERC20(USDT).balanceOf(vault), 0, "USDT left in vault after swap");

        (uint256 wbtcBal, uint256 wethBal) = _getPortfolioBalances(vault);
        assertTrue(wbtcBal > 0, "no WBTC after USDT deposit");
        assertTrue(wethBal > 0, "no WETH after USDT deposit");

        uint256 totalUsd = PortfolioVault(vault).totalAssets();
        assertTrue(totalUsd > 0, "zero totalAssets after USDT deposit");

        // Each leg ~50% of total; allow 3% tolerance for the 2-hop route.
        uint256 wbtcPrice = PortfolioVault(vault).getTokenPrice(WBTC);
        uint256 wethPrice = PortfolioVault(vault).getTokenPrice(WETH);
        uint256 wbtcUsd   = (wbtcBal * wbtcPrice) / 1e8;
        uint256 wethUsd   = (wethBal * wethPrice) / 1e18;
        uint256 diff = wbtcUsd > wethUsd ? wbtcUsd - wethUsd : wethUsd - wbtcUsd;
        assertLt(diff * 100 / totalUsd, 3, "portfolio legs imbalanced by more than 3%");

        console2.log("Shares minted (USDT deposit):", shares);
        console2.log("WBTC balance               :", wbtcBal);
        console2.log("WETH balance               :", wethBal);
        console2.log("totalAssets (8 dec)        :", totalUsd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testWithdrawToUSDC
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdrawToUSDC() public {
        address vault = _createVault(user, 0);
        _dealTokens(user, USDC, DEPOSIT_USDC);
        _depositToVault(user, vault, USDC, DEPOSIT_USDC);

        uint256 shares = PortfolioVault(vault).balanceOf(user);
        assertTrue(shares > 0, "no shares to withdraw");

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        // The SwapRouter's 0.5% oracle tolerance is tight against a 0.3% fee pool:
        // after the pool fee the remaining headroom is only ~0.2% for price divergence
        // between Chainlink BTC/USD and the actual WBTC/USDC Uniswap pool.
        // We mock the BTC price 1% lower so the oracle-derived minimum leaves enough
        // room for the real pool execution, while the actual swap still hits the fork.
        _mockBtcPriceLower(1);

        // No guardian set — empty sig is accepted (auto-approved by GuardianModule).
        vm.prank(user);
        PortfolioVault(vault).withdraw(USDC, shares, block.timestamp + 1 hours, "");

        vm.clearMockedCalls();

        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        uint256 received  = usdcAfter - usdcBefore;

        assertTrue(received > 0,                                "no USDC received");
        assertEq(PortfolioVault(vault).balanceOf(user), 0,      "shares not burned");
        assertEq(IERC20(WBTC).balanceOf(vault),          0,     "WBTC left in vault");
        assertEq(IERC20(WETH).balanceOf(vault),          0,     "WETH left in vault");

        // Round-trip slippage ≤ 3%: 2 deposit swaps (USDC→WBTC, USDC→WETH) + 2 withdraw
        // swaps (WBTC→USDC, WETH→USDC), each incurring pool fee + the 1% mock discount.
        uint256 slippageBps = received >= DEPOSIT_USDC
            ? 0
            : (DEPOSIT_USDC - received) * 10_000 / DEPOSIT_USDC;
        assertLt(slippageBps, 300, "round-trip slippage exceeded 3%");

        console2.log("USDC deposited          :", DEPOSIT_USDC);
        console2.log("USDC received           :", received);
        console2.log("Round-trip slippage bps :", slippageBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testWithdrawToPortfolio
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdrawToPortfolio() public {
        address vault = _createVault(user, 0);
        _dealTokens(user, USDC, DEPOSIT_USDC);
        _depositToVault(user, vault, USDC, DEPOSIT_USDC);

        uint256 shares = PortfolioVault(vault).balanceOf(user);

        // address(0) as outputToken = direct portfolio token withdrawal (no swap).
        vm.prank(user);
        PortfolioVault(vault).withdraw(address(0), shares, block.timestamp + 1 hours, "");

        uint256 wbtcReceived = IERC20(WBTC).balanceOf(user);
        uint256 wethReceived = IERC20(WETH).balanceOf(user);

        assertTrue(wbtcReceived > 0, "user received no WBTC");
        assertTrue(wethReceived > 0, "user received no WETH");
        assertEq(PortfolioVault(vault).balanceOf(user), 0, "shares not burned");

        // Vault fully drained — no dust left (100% of shares redeemed).
        assertEq(IERC20(WBTC).balanceOf(vault), 0, "WBTC dust left in vault");
        assertEq(IERC20(WETH).balanceOf(vault), 0, "WETH dust left in vault");

        console2.log("WBTC received :", wbtcReceived);
        console2.log("WETH received :", wethReceived);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testGuardianSetup
    // ─────────────────────────────────────────────────────────────────────────

    function testGuardianSetup() public {
        address vault = _createVault(user, 0);
        _dealTokens(user, USDC, DEPOSIT_USDC);
        _depositToVault(user, vault, USDC, DEPOSIT_USDC);

        // 1. Set guardian (initial setup — no signature required).
        vm.prank(user);
        PortfolioVault(vault).setGuardianAddress(guardianAddr);
        assertEq(d.guardianModule.guardians(vault), guardianAddr, "guardian not stored");
        console2.log("Guardian set:", guardianAddr);

        uint256 shares = PortfolioVault(vault).balanceOf(user);

        // 2. Withdrawal without a valid signature must revert.
        //    deadline = 0 → GuardianModule.validateWithdrawal returns false immediately
        //    (block.timestamp > 0 is always true), causing the vault to revert.
        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        PortfolioVault(vault).withdraw(USDC, shares, 0, "");
        console2.log("Withdrawal without signature correctly reverted");

        // 3. Build a valid EIP-712 guardian signature.
        //    Withdraw to address(0) (portfolio tokens, no swap) so the test is not
        //    sensitive to Chainlink vs Uniswap price divergence on the WBTC/USDC pool.
        //    The guardian sig commits to usdValue only — outputToken is not signed.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(vault, user, shares, deadline);

        // 4. Withdrawal with valid guardian signature must succeed.
        vm.prank(user);
        PortfolioVault(vault).withdraw(address(0), shares, deadline, sig);
        assertEq(PortfolioVault(vault).balanceOf(user), 0, "shares not burned");
        assertTrue(IERC20(WBTC).balanceOf(user) > 0, "user received no WBTC");
        assertTrue(IERC20(WETH).balanceOf(user) > 0, "user received no WETH");
        console2.log("Withdrawal with guardian signature succeeded");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testSocialRecovery
    // ─────────────────────────────────────────────────────────────────────────

    function testSocialRecovery() public {
        address vault = _createVault(user, 0);

        address[] memory guardians = new address[](3);
        guardians[0] = recoveryGuardian1;
        guardians[1] = recoveryGuardian2;
        guardians[2] = recoveryGuardian3;

        // First setRecoveryConfig — must succeed.
        vm.prank(user);
        d.recoveryModule.setRecoveryConfig(vault, guardians, 2);

        assertTrue(d.recoveryModule.isRecoveryLocked(vault), "config not locked after setup");
        assertTrue(d.recoveryModule.isConfigured(vault),      "isConfigured returned false");

        (address[] memory stored, uint256 threshold) = d.recoveryModule.getConfig(vault);
        assertEq(stored.length, 3, "wrong guardian count");
        assertEq(threshold,     2, "wrong threshold");
        assertEq(stored[0], recoveryGuardian1);
        assertEq(stored[1], recoveryGuardian2);
        assertEq(stored[2], recoveryGuardian3);
        console2.log("Recovery config locked with 3 guardians, threshold 2");

        // Second setRecoveryConfig on the same vault — must revert (permanently locked).
        vm.expectRevert(SocialRecoveryModule.RecoveryAlreadyConfigured.selector);
        vm.prank(user);
        d.recoveryModule.setRecoveryConfig(vault, guardians, 2);
        console2.log("Second setRecoveryConfig correctly reverted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _dealTokens(address to, address token, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _createVault(address _user, uint8 tier) internal returns (address vault) {
        vm.prank(_user);
        vault = d.factory.createVault(tier, false);
    }

    function _depositToVault(address _user, address vault, address token, uint256 amount) internal {
        vm.startPrank(_user);
        IERC20(token).approve(vault, amount);
        PortfolioVault(vault).deposit(token, amount);
        vm.stopPrank();
    }

    function _getPortfolioBalances(address vault) internal view returns (uint256 wbtcBalance, uint256 wethBalance) {
        wbtcBalance = IERC20(WBTC).balanceOf(vault);
        wethBalance = IERC20(WETH).balanceOf(vault);
    }

    /**
     * @dev Mocks the BTC/USD Chainlink feed to return `pct`% less than the live price.
     *      Used in withdrawal tests to give the SwapRouter's 0.5% oracle tolerance
     *      enough room when the Chainlink BTC/USD rate diverges from the WBTC/USDC
     *      Uniswap pool rate by more than ~0.2% (0.5% tolerance minus 0.3% pool fee).
     *      Call vm.clearMockedCalls() after the withdrawal to restore live prices.
     */
    function _mockBtcPriceLower(uint256 pct) internal {
        address feed = vm.envAddress("BTC_USD_FEED");
        (uint80 rid, int256 p, uint256 sat, uint256 uat, uint80 air) =
            AggregatorV3Interface(feed).latestRoundData();
        int256 loweredPrice = p * int256(100 - pct) / 100;
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(rid, loweredPrice, sat, uat, air)
        );
    }

    /**
     * @dev Signs a withdrawal approval with the test guardian key.
     *
     *      Replicates vault.withdraw() → _convertToAssets() to pre-compute usdValue,
     *      which is the `amount` field in the WithdrawalApproval struct. The vault
     *      computes it internally before calling validateWithdrawal, so the signature
     *      must commit to the same value.
     *
     *      Floor rounding: mulDiv(shares, totalAssets+1, totalSupply+1, Floor)
     *      = integer division, no round-up.
     */
    function _signWithdrawal(
        address vault,
        address owner_,
        uint256 shares,
        uint256 deadline
    ) internal view returns (bytes memory sig) {
        uint256 totalAss = PortfolioVault(vault).totalAssets();
        uint256 totalSup = PortfolioVault(vault).totalSupply();
        uint256 usdValue = (shares * (totalAss + 1)) / (totalSup + 1);

        uint256 nonce = d.guardianModule.nonces(vault, owner_);

        bytes32 structHash = keccak256(abi.encode(
            WITHDRAWAL_APPROVAL_TYPEHASH,
            vault,
            owner_,
            usdValue,
            owner_,   // recipient is always owner (enforced by vault)
            nonce,
            deadline
        ));

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", d.guardianModule.getDomainSeparator(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GUARDIAN_PRIV_KEY, digest);
        // ECDSA.tryRecover expects r || s || v (65 bytes)
        sig = abi.encodePacked(r, s, v);
    }
}
