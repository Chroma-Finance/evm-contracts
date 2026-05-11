// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {GuardianModule} from "../src/modules/GuardianModule.sol";
import {SocialRecoveryModule} from "../src/modules/SocialRecoveryModule.sol";
import {YieldOptimizer} from "../src/modules/YieldOptimizer.sol";
import {SwapRouter} from "../src/utils/SwapRouter.sol";
import {FeeManager} from "../src/utils/FeeManager.sol";
import {RiskTierRegistry} from "../src/utils/RiskTierRegistry.sol";

/**
 * @notice Deploys the full Chroma Finance protocol stack on Arbitrum One.
 *
 *         Required env vars:
 *           PRIVATE_KEY    — deployer private key
 *           TREASURY_ADDR  — protocol treasury multisig
 *           DEV_FUND_ADDR  — developer fund multisig
 *           DENOMINATION   — denomination asset (e.g., USDC on Arbitrum)
 *
 *         After deploying, the owner must call RiskTierRegistry.createTier() to
 *         populate the three risk tiers with Arbitrum token addresses:
 *
 *         Tier 0 — Low Risk    : 40% WBTC | 30% XAUT | 30% PAXG
 *         Tier 1 — Medium Risk : 25% WBTC | 25% WETH | 20% XAUT | 20% PAXG | 10% wstETH
 *         Tier 2 — High Risk   : 25% WBTC | 25% WETH | 15% wstETH | 10% XAUT | 10% PAXG | 15% Alts
 */
contract DeployScript is Script {
    // ─── Arbitrum One addresses ───────────────────────────────────────────────

    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Tokens
    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH  = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC  = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant USDT  = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI   = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    // Chainlink price feeds (Arbitrum One)
    address constant FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant FEED_WETH = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant FEED_WBTC = 0x6ce185860a4963106506C203335A2910413708e9;

    function run() external {
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address treasury     = vm.envOr("TREASURY_ADDR", deployer); // fallback to deployer for testing
        address devFund      = vm.envOr("DEV_FUND_ADDR",  deployer);
        address denomination = vm.envOr("DENOMINATION",    address(0));

        // denomination must be set for VaultFactory; use address(1) as placeholder for local testing
        if (denomination == address(0)) denomination = address(1);

        vm.startBroadcast(deployerKey);

        // 1. Deploy supporting contracts
        RiskTierRegistry registry = new RiskTierRegistry();
        console2.log("RiskTierRegistry :", address(registry));

        FeeManager feeManager = new FeeManager(treasury, devFund);
        console2.log("FeeManager       :", address(feeManager));

        SwapRouter swapRouter = new SwapRouter(UNISWAP_ROUTER);
        console2.log("SwapRouter       :", address(swapRouter));

        // Configure SwapRouter — price feeds
        swapRouter.setPriceFeed(USDC, FEED_USDC);
        swapRouter.setPriceFeed(WETH, FEED_WETH);
        swapRouter.setPriceFeed(WBTC, FEED_WBTC);

        // Configure SwapRouter — pool fee tiers (Uniswap V3 Arbitrum)
        swapRouter.setPoolFee(USDC, WETH,  500);   // 0.05%
        swapRouter.setPoolFee(USDC, WBTC,  3000);  // 0.30%
        swapRouter.setPoolFee(USDC, USDT,  100);   // 0.01%
        swapRouter.setPoolFee(USDC, DAI,   100);   // 0.01%
        swapRouter.setPoolFee(WETH, WBTC,  3000);  // 0.30%

        // 2. Deploy core factory (requires registry + denomination asset + fee manager)
        VaultFactory factory = new VaultFactory(denomination, address(registry), address(feeManager));
        console2.log("VaultFactory     :", address(factory));

        // 3. Deploy optional/module contracts
        YieldOptimizer optimizer = new YieldOptimizer(address(factory));
        console2.log("YieldOptimizer   :", address(optimizer));

        GuardianModule guardian = new GuardianModule();
        console2.log("GuardianModule   :", address(guardian));

        SocialRecoveryModule recovery = new SocialRecoveryModule();
        console2.log("SocialRecovery   :", address(recovery));

        // TODO: Populate risk tiers via registry.createTier() with Arbitrum token addresses.
        // TODO: After creating each vault, call vault.setSwapRouter(address(swapRouter))
        //       and swapRouter.setAuthorizedVault(vaultAddress).
        // TODO: Transfer ownership of registry/feeManager/factory to governance multisig.

        vm.stopBroadcast();
    }
}
