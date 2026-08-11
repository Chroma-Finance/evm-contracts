// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

contract RiskTierRegistryTest is Test {
    RiskTierRegistry internal registry;

    address internal attacker = makeAddr("attacker");
    address internal assetA   = makeAddr("assetA");
    address internal assetB   = makeAddr("assetB");
    address internal feedA    = makeAddr("feedA");
    address internal feedB    = makeAddr("feedB");

    function setUp() public {
        registry = new RiskTierRegistry();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _createDefaultTier(uint8 id) internal {
        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        registry.createTier(id, "Test Tier", t, w, f);
    }

    // ─── Tier creation ────────────────────────────────────────────────────────

    function test_createTier_succeeds() public {
        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        registry.createTier(0, "Low Risk", t, w, f);

        (address[] memory assets, uint256[] memory weights, address[] memory feeds) = registry.getTier(0);
        assertEq(assets.length, 1);
        assertEq(assets[0], assetA);
        assertEq(weights[0], 10_000);
        assertEq(feeds[0], feedA);
    }

    function test_createTier_onlyOwner_reverts() public {
        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        vm.prank(attacker);
        vm.expectRevert();
        registry.createTier(0, "Low Risk", t, w, f);
    }

    function test_createTier_duplicateId_reverts() public {
        _createDefaultTier(0);
        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        vm.expectRevert(RiskTierRegistry.TierAlreadyExists.selector);
        registry.createTier(0, "Duplicate", t, w, f);
    }

    function test_createTier_emptyAssets_reverts() public {
        address[] memory t = new address[](0);
        uint256[] memory w = new uint256[](0);
        address[] memory f = new address[](0);
        vm.expectRevert(RiskTierRegistry.EmptyAssets.selector);
        registry.createTier(0, "Empty", t, w, f);
    }

    function test_createTier_weightsNotSumTo10000_reverts() public {
        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 9_999;
        address[] memory f = new address[](1); f[0] = feedA;
        vm.expectRevert(RiskTierRegistry.InvalidWeights.selector);
        registry.createTier(0, "Bad Weights", t, w, f);
    }

    function test_createTier_zeroAddressAsset_reverts() public {
        address[] memory t = new address[](1); t[0] = address(0);
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        vm.expectRevert(RiskTierRegistry.ZeroAddress.selector);
        registry.createTier(0, "Zero Asset", t, w, f);
    }

    function test_createTier_mismatchedArrayLengths_reverts() public {
        address[] memory t = new address[](2); t[0] = assetA; t[1] = assetB;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](2); f[0] = feedA;  f[1] = feedB;
        vm.expectRevert(RiskTierRegistry.LengthMismatch.selector);
        registry.createTier(0, "Mismatch", t, w, f);
    }

    // ─── Tier reading ─────────────────────────────────────────────────────────

    function test_getTier_returnsCorrectData() public {
        address[] memory t = new address[](2); t[0] = assetA; t[1] = assetB;
        uint256[] memory w = new uint256[](2); w[0] = 6_000;  w[1] = 4_000;
        address[] memory f = new address[](2); f[0] = feedA;  f[1] = feedB;
        registry.createTier(1, "Medium Risk", t, w, f);

        (address[] memory assets, uint256[] memory weights, address[] memory feeds) = registry.getTier(1);
        assertEq(assets.length, 2);
        assertEq(assets[0], assetA);
        assertEq(assets[1], assetB);
        assertEq(weights[0], 6_000);
        assertEq(weights[1], 4_000);
        assertEq(feeds[0], feedA);
        assertEq(feeds[1], feedB);
    }

    function test_getTier_nonExistent_reverts() public {
        vm.expectRevert(RiskTierRegistry.TierNotFound.selector);
        registry.getTier(99);
    }

    function test_getTierAssets_returnsCorrectAddresses() public {
        address[] memory t = new address[](2); t[0] = assetA; t[1] = assetB;
        uint256[] memory w = new uint256[](2); w[0] = 6_000;  w[1] = 4_000;
        address[] memory f = new address[](2); f[0] = feedA;  f[1] = feedB;
        registry.createTier(0, "Low Risk", t, w, f);

        (address[] memory assets,) = registry.getTierAssets(0);
        assertEq(assets.length, 2);
        assertEq(assets[0], assetA);
        assertEq(assets[1], assetB);
    }

    function test_getTierWeights_returnsCorrectWeights() public {
        address[] memory t = new address[](2); t[0] = assetA; t[1] = assetB;
        uint256[] memory w = new uint256[](2); w[0] = 6_000;  w[1] = 4_000;
        address[] memory f = new address[](2); f[0] = feedA;  f[1] = feedB;
        registry.createTier(0, "Low Risk", t, w, f);

        (, uint256[] memory weights) = registry.getTierAssets(0);
        assertEq(weights.length, 2);
        assertEq(weights[0], 6_000);
        assertEq(weights[1], 4_000);
    }

    function test_tierExists_trueAndFalse() public {
        // Non-existent tier returns empty arrays from getTierAssets.
        (address[] memory none,) = registry.getTierAssets(0);
        assertEq(none.length, 0);

        // After creation, getTierAssets returns the registered assets.
        _createDefaultTier(0);
        (address[] memory existing,) = registry.getTierAssets(0);
        assertGt(existing.length, 0);
    }

    // ─── Multiple tiers ───────────────────────────────────────────────────────

    function test_multipleTiers_independentData() public {
        // Tier 0: single asset
        {
            address[] memory t = new address[](1); t[0] = assetA;
            uint256[] memory w = new uint256[](1); w[0] = 10_000;
            address[] memory f = new address[](1); f[0] = feedA;
            registry.createTier(0, "Low Risk", t, w, f);
        }
        // Tier 1: two assets
        {
            address[] memory t = new address[](2); t[0] = assetA; t[1] = assetB;
            uint256[] memory w = new uint256[](2); w[0] = 6_000;  w[1] = 4_000;
            address[] memory f = new address[](2); f[0] = feedA;  f[1] = feedB;
            registry.createTier(1, "Medium Risk", t, w, f);
        }

        (address[] memory assets0,,) = registry.getTier(0);
        (address[] memory assets1,,) = registry.getTier(1);
        assertEq(assets0.length, 1);
        assertEq(assets1.length, 2);
        assertEq(assets0[0], assetA);
        assertEq(assets1[1], assetB);
    }

    function test_getTierCount_incrementsOnCreate() public {
        assertEq(registry.tierCount(), 0);

        _createDefaultTier(0);
        assertEq(registry.tierCount(), 1);

        address[] memory t = new address[](1); t[0] = assetA;
        uint256[] memory w = new uint256[](1); w[0] = 10_000;
        address[] memory f = new address[](1); f[0] = feedA;
        registry.createTier(1, "Tier 1", t, w, f);
        assertEq(registry.tierCount(), 2);
    }
}
