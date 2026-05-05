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
    // ─── Arbitrum One — Uniswap V3 SwapRouter ────────────────────────────────
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

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
        // TODO: Transfer ownership of registry/feeManager/factory to governance multisig.

        vm.stopBroadcast();
    }
}
