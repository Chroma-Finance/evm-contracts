// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

/*
 * SaveDeployment.s.sol
 *
 * Reads deployed contract addresses from an on-chain VaultFactory and
 * writes a JSON manifest consumed by the frontend.
 *
 * Usage (after any deployment):
 *
 *   export VAULT_FACTORY_ADDR=0x...
 *   export NETWORK_NAME=arbitrum-one          # optional, default: arbitrum-one
 *   export DEPLOYMENT_OUTPUT_PATH=frontend/src/contracts/deployed.json  # optional
 *
 *   forge script script/SaveDeployment.s.sol \
 *     --rpc-url $ARBITRUM_RPC_URL \
 *     -vvv
 *
 * For a local fork:
 *
 *   NETWORK_NAME=arbitrum-local-fork \
 *   forge script script/SaveDeployment.s.sol \
 *     --rpc-url http://localhost:8545 \
 *     -vvv
 *
 * Frontend import (TypeScript / Next.js):
 *
 *   import deployment from "src/contracts/deployed.json";
 *   const factoryAddress = deployment.contracts.VaultFactory;
 *
 * All module addresses (GuardianModule, SocialRecoveryModule, EventNotifier) are
 * derived from the factory's public getters — no separate env vars required.
 */
contract SaveDeployment is Script {
    function run() external {
        address factoryAddr = vm.envAddress("VAULT_FACTORY_ADDR");
        string memory network = vm.envOr("NETWORK_NAME", string("arbitrum-one"));
        string memory outputPath = vm.envOr(
            "DEPLOYMENT_OUTPUT_PATH",
            string("frontend/src/contracts/deployed.json")
        );

        VaultFactory factory = VaultFactory(factoryAddr);

        address swapRouter     = factory.swapRouter();
        address riskRegistry   = factory.riskRegistry();
        address feeManager     = factory.feeRecipient();
        address eventNotifier  = factory.eventNotifier();
        address guardianModule = factory.getGuardianModule();
        address recoveryModule = factory.getRecoveryModule();

        _log(factoryAddr, guardianModule, recoveryModule, swapRouter, riskRegistry, eventNotifier, feeManager);

        // ── Build JSON ────────────────────────────────────────────────────────

        string memory c = "contracts";
        vm.serializeAddress(c, "VaultFactory",         factoryAddr);
        vm.serializeAddress(c, "GuardianModule",       guardianModule);
        vm.serializeAddress(c, "SocialRecoveryModule", recoveryModule);
        vm.serializeAddress(c, "SwapRouter",           swapRouter);
        vm.serializeAddress(c, "RiskTierRegistry",     riskRegistry);
        vm.serializeAddress(c, "EventNotifier",        eventNotifier);
        string memory contractsJson = vm.serializeAddress(c, "FeeManager", feeManager);

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "network", network);
        string memory finalJson = vm.serializeString(root, "contracts", contractsJson);

        vm.writeJson(finalJson, outputPath);
        console2.log("");
        console2.log("Saved to", outputPath);
    }

    function _log(
        address factory,
        address guardian,
        address recovery,
        address swapRouter,
        address registry,
        address notifier,
        address feeManager
    ) internal pure {
        console2.log("=== Chroma Finance deployment addresses ===");
        console2.log("VaultFactory        :", factory);
        console2.log("GuardianModule      :", guardian);
        console2.log("SocialRecoveryModule:", recovery);
        console2.log("SwapRouter          :", swapRouter);
        console2.log("RiskTierRegistry    :", registry);
        console2.log("EventNotifier       :", notifier);
        console2.log("FeeManager          :", feeManager);
    }
}
