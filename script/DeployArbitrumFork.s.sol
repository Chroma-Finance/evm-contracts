// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory}          from "../src/core/VaultFactory.sol";
import {EventNotifier}         from "../src/core/EventNotifier.sol";
import {GuardianModule}        from "../src/modules/GuardianModule.sol";
import {SocialRecoveryModule}  from "../src/modules/SocialRecoveryModule.sol";
import {SwapRouter}            from "../src/utils/SwapRouter.sol";
import {RiskTierRegistry}      from "../src/utils/RiskTierRegistry.sol";
import {FeeManager}            from "../src/utils/FeeManager.sol";

/**
 * @notice Deploys and wires the full Chroma Finance protocol on an Arbitrum mainnet fork.
 *
 * All external addresses are loaded from environment variables so the same script
 * works against any Arbitrum fork block without edits.
 *
 * Architecture note
 * -----------------
 * VaultFactory deploys EventNotifier, GuardianModule, and SocialRecoveryModule
 * internally in its constructor and authorizes itself in the EventNotifier.
 * Those contracts are not deployed separately here; they are retrieved from the
 * factory's public getters after construction and exposed in the Deployments struct.
 *
 * Required env vars (all present in .env.example):
 *   ARBITRUM_RPC_URL   — fork target
 *   PRIVATE_KEY        — deployer key
 *   UNISWAP_V3_ROUTER  — Arbitrum Uniswap V3 SwapRouter
 *   WBTC, WETH, USDC, USDT, DAI
 *   BTC_USD_FEED, ETH_USD_FEED
 */
contract DeployArbitrumFork is Script {

    // ─── Return struct ────────────────────────────────────────────────────────

    struct Deployments {
        // Independently deployed
        SwapRouter          swapRouter;
        RiskTierRegistry    riskRegistry;
        FeeManager          feeManager;
        VaultFactory        factory;
        // Deployed internally by VaultFactory constructor
        EventNotifier       eventNotifier;
        GuardianModule      guardianModule;
        SocialRecoveryModule recoveryModule;
    }

    // ─── run ─────────────────────────────────────────────────────────────────

    function run() external returns (Deployments memory d) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // ── Load Arbitrum addresses from env ──────────────────────────────────
        address uniswapRouter = vm.envAddress("UNISWAP_V3_ROUTER");
        address wbtc          = vm.envAddress("WBTC");
        address weth          = vm.envAddress("WETH");
        address usdc          = vm.envAddress("USDC");
        address usdt          = vm.envAddress("USDT");
        address dai           = vm.envAddress("DAI");
        address btcUsdFeed    = vm.envAddress("BTC_USD_FEED");
        address ethUsdFeed    = vm.envAddress("ETH_USD_FEED");

        _requireNonZero("UNISWAP_V3_ROUTER", uniswapRouter);
        _requireNonZero("WBTC",              wbtc);
        _requireNonZero("WETH",              weth);
        _requireNonZero("USDC",              usdc);
        _requireNonZero("USDT",              usdt);
        _requireNonZero("DAI",               dai);
        _requireNonZero("BTC_USD_FEED",      btcUsdFeed);
        _requireNonZero("ETH_USD_FEED",      ethUsdFeed);

        console2.log("=== Chroma Finance - Arbitrum fork deployment ===");
        console2.log("Deployer         :", deployer);
        console2.log("Block            :", block.number);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. SwapRouter ─────────────────────────────────────────────────────
        // Wraps Uniswap V3 with Chainlink oracle-validated slippage protection.
        d.swapRouter = new SwapRouter(uniswapRouter);
        console2.log("SwapRouter       :", address(d.swapRouter));

        // ── 2. RiskTierRegistry ───────────────────────────────────────────────
        d.riskRegistry = new RiskTierRegistry();
        console2.log("RiskTierRegistry :", address(d.riskRegistry));

        // ── 3. FeeManager ─────────────────────────────────────────────────────
        // Both treasury and devFund point to the deployer for fork/test deployments.
        d.feeManager = new FeeManager(deployer, deployer);
        console2.log("FeeManager       :", address(d.feeManager));

        // ── 4. VaultFactory ───────────────────────────────────────────────────
        // Constructor internally deploys EventNotifier, GuardianModule, and
        // SocialRecoveryModule, then authorizes the factory in the EventNotifier.
        d.factory = new VaultFactory(
            address(d.swapRouter),
            address(d.riskRegistry),
            address(d.feeManager)
        );
        console2.log("VaultFactory     :", address(d.factory));

        // Retrieve the three internally-deployed modules.
        d.eventNotifier  = EventNotifier(d.factory.eventNotifier());
        d.guardianModule = GuardianModule(d.factory.getGuardianModule());
        d.recoveryModule = SocialRecoveryModule(d.factory.getRecoveryModule());
        console2.log("EventNotifier    :", address(d.eventNotifier));
        console2.log("GuardianModule   :", address(d.guardianModule));
        console2.log("SocialRecovery   :", address(d.recoveryModule));
        console2.log("");

        // ── 5. Protocol wire-up ───────────────────────────────────────────────
        // EventNotifier: factory authorizes itself during construction.
        // Assert the invariant is satisfied rather than duplicating the call.
        require(
            d.eventNotifier.authorized(address(d.factory)),
            "factory not authorized in EventNotifier"
        );
        console2.log("EventNotifier auth  : factory authorized (by constructor)");

        // SwapRouter: already wired via VaultFactory constructor argument.
        // Assert the state is correct.
        require(
            d.factory.swapRouter() == address(d.swapRouter),
            "swapRouter mismatch in factory"
        );
        console2.log("SwapRouter in factory: confirmed");

        // Allow factory to call SwapRouter.authorizeVault() on each createVault().
        d.swapRouter.setFactory(address(d.factory));
        console2.log("SwapRouter factory   :", address(d.factory));
        console2.log("");

        // ── 6. Configure SwapRouter ───────────────────────────────────────────

        // Price feeds
        d.swapRouter.setPriceFeed(wbtc, btcUsdFeed);
        d.swapRouter.setPriceFeed(weth, ethUsdFeed);
        console2.log("Price feeds set for WBTC and WETH");

        // Token whitelist — accepted as deposit input or withdrawal output
        d.swapRouter.whitelistToken(usdc);
        d.swapRouter.whitelistToken(usdt);
        d.swapRouter.whitelistToken(dai);
        d.swapRouter.whitelistToken(wbtc);
        d.swapRouter.whitelistToken(weth);
        console2.log("Tokens whitelisted: USDC, USDT, DAI, WBTC, WETH");

        // Uniswap V3 pool fees
        d.swapRouter.setPoolFee(wbtc, weth, 3000); // 0.30%
        d.swapRouter.setPoolFee(weth, usdc, 500);  // 0.05%
        d.swapRouter.setPoolFee(wbtc, usdc, 3000); // 0.30%
        d.swapRouter.setPoolFee(usdt, usdc, 100);  // 0.01%
        d.swapRouter.setPoolFee(dai,  usdc, 100);  // 0.01%
        console2.log("Pool fees set for 5 pairs");

        // ── 7. Multi-hop paths (USDT and DAI have no direct pools vs WBTC/WETH) ─
        // Route: stablecoin → USDC (0.01%) → WBTC (0.30%) or WETH (0.05%)
        d.swapRouter.setSwapPath(usdt, wbtc, abi.encodePacked(usdt, uint24(100), usdc, uint24(3000), wbtc));
        d.swapRouter.setSwapPath(usdt, weth, abi.encodePacked(usdt, uint24(100), usdc, uint24(500),  weth));
        d.swapRouter.setSwapPath(dai,  wbtc, abi.encodePacked(dai,  uint24(100), usdc, uint24(3000), wbtc));
        d.swapRouter.setSwapPath(dai,  weth, abi.encodePacked(dai,  uint24(100), usdc, uint24(500),  weth));
        console2.log("Multi-hop paths set: USDT->WBTC, USDT->WETH, DAI->WBTC, DAI->WETH");
        console2.log("");

        // ── 8. Create Tier 0 — Low Risk (50% WBTC | 50% WETH) ───────────────
        {
            address[] memory assets  = new address[](2);
            uint256[] memory weights = new uint256[](2);
            address[] memory feeds   = new address[](2);

            assets[0]  = wbtc;       weights[0] = 5_000; feeds[0] = btcUsdFeed;
            assets[1]  = weth;       weights[1] = 5_000; feeds[1] = ethUsdFeed;

            d.riskRegistry.createTier(0, "Low Risk", assets, weights, feeds);
            console2.log("Tier 0 created: Low Risk (50% WBTC | 50% WETH)");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment complete ===");
        console2.log("SwapRouter       :", address(d.swapRouter));
        console2.log("RiskTierRegistry :", address(d.riskRegistry));
        console2.log("FeeManager       :", address(d.feeManager));
        console2.log("VaultFactory     :", address(d.factory));
        console2.log("EventNotifier    :", address(d.eventNotifier));
        console2.log("GuardianModule   :", address(d.guardianModule));
        console2.log("SocialRecovery   :", address(d.recoveryModule));
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _requireNonZero(string memory name_, address addr) internal pure {
        require(addr != address(0), string.concat(name_, " must not be zero address"));
    }
}
