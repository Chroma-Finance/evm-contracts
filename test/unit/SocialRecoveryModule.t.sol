// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {SocialRecoveryModule} from "../../src/modules/SocialRecoveryModule.sol";

// ─── Minimal vault stub ──────────────────────────────────────────────────────

contract MockVault {
    address public owner;
    address public lastGuardianSet;
    address public recoveryModule;

    constructor(address owner_) {
        owner = owner_;
    }

    function setRecoveryModule(address rm) external {
        recoveryModule = rm;
    }

    function transferOwnership(address newOwner) external {
        owner = newOwner;
    }

    function setGuardianAddress(address newGuardian) external {
        lastGuardianSet = newGuardian;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

contract SocialRecoveryModuleTest is Test {
    SocialRecoveryModule internal recovery;
    MockVault            internal vault;

    address internal vaultOwner = makeAddr("vaultOwner");

    // Five guardian keys
    uint256 internal keyA = 0xA1;
    uint256 internal keyB = 0xB2;
    uint256 internal keyC = 0xC3;
    uint256 internal keyD = 0xD4;
    uint256 internal keyE = 0xE5;

    address internal guardianA;
    address internal guardianB;
    address internal guardianC;
    address internal guardianD;
    address internal guardianE;

    // 3-of-5 default setup
    address[] internal guardians5;
    uint256   internal threshold3 = 3;

    function setUp() public {
        recovery = new SocialRecoveryModule();
        vault    = new MockVault(vaultOwner);
        vault.setRecoveryModule(address(recovery));

        guardianA = vm.addr(keyA);
        guardianB = vm.addr(keyB);
        guardianC = vm.addr(keyC);
        guardianD = vm.addr(keyD);
        guardianE = vm.addr(keyE);

        guardians5 = new address[](5);
        guardians5[0] = guardianA;
        guardians5[1] = guardianB;
        guardians5[2] = guardianC;
        guardians5[3] = guardianD;
        guardians5[4] = guardianE;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _setConfig3of5() internal {
        vm.prank(vaultOwner);
        recovery.setRecoveryConfig(address(vault), guardians5, threshold3);
    }

    function _signOwnership(uint256 key, address newOwner, uint256 nonce)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            recovery.OWNERSHIP_RECOVERY_TYPEHASH(),
            address(vault),
            newOwner,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", recovery.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signGuardian(uint256 key, address newGuardian, uint256 nonce)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            recovery.GUARDIAN_RECOVERY_TYPEHASH(),
            address(vault),
            newGuardian,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", recovery.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _ownershipSigs3(address newOwner) internal view returns (bytes[] memory sigs) {
        uint256 nonce = recovery.nonces(address(vault));
        sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, newOwner, nonce);
        sigs[1] = _signOwnership(keyB, newOwner, nonce);
        sigs[2] = _signOwnership(keyC, newOwner, nonce);
    }

    function _guardianSigs3(address newGuardian) internal view returns (bytes[] memory sigs) {
        uint256 nonce = recovery.nonces(address(vault));
        sigs = new bytes[](3);
        sigs[0] = _signGuardian(keyA, newGuardian, nonce);
        sigs[1] = _signGuardian(keyB, newGuardian, nonce);
        sigs[2] = _signGuardian(keyC, newGuardian, nonce);
    }

    // ─── setRecoveryConfig ────────────────────────────────────────────────────

    function test_setRecoveryConfig_valid() public {
        _setConfig3of5();
        (address[] memory g, uint256 t) = recovery.getConfig(address(vault));
        assertEq(g.length, 5);
        assertEq(t, 3);
        assertEq(g[0], guardianA);
    }

    function test_setRecoveryConfig_onlyOwner_reverts() public {
        vm.expectRevert(SocialRecoveryModule.Unauthorized.selector);
        recovery.setRecoveryConfig(address(vault), guardians5, threshold3);
    }

    function test_setRecoveryConfig_tooFewGuardians_reverts() public {
        address[] memory one = new address[](1);
        one[0] = guardianA;
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.InvalidConfig.selector);
        recovery.setRecoveryConfig(address(vault), one, 1);
    }

    function test_setRecoveryConfig_tooManyGuardians_reverts() public {
        address[] memory six = new address[](6);
        for (uint256 i = 0; i < 6; i++) six[i] = makeAddr(string(abi.encode(i)));
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.InvalidConfig.selector);
        recovery.setRecoveryConfig(address(vault), six, 3);
    }

    function test_setRecoveryConfig_thresholdTooLow_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.InvalidConfig.selector);
        recovery.setRecoveryConfig(address(vault), guardians5, 1); // below MIN_THRESHOLD=2
    }

    function test_setRecoveryConfig_thresholdAboveCount_reverts() public {
        address[] memory two = new address[](2);
        two[0] = guardianA;
        two[1] = guardianB;
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.InvalidConfig.selector);
        recovery.setRecoveryConfig(address(vault), two, 3); // 3 > 2
    }

    function test_setRecoveryConfig_duplicateGuardian_reverts() public {
        address[] memory dups = new address[](3);
        dups[0] = guardianA;
        dups[1] = guardianB;
        dups[2] = guardianA; // duplicate
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.InvalidConfig.selector);
        recovery.setRecoveryConfig(address(vault), dups, 2);
    }

    function test_setRecoveryConfig_zeroAddressGuardian_reverts() public {
        address[] memory withZero = new address[](3);
        withZero[0] = guardianA;
        withZero[1] = address(0);
        withZero[2] = guardianC;
        vm.prank(vaultOwner);
        vm.expectRevert(SocialRecoveryModule.ZeroAddress.selector);
        recovery.setRecoveryConfig(address(vault), withZero, 2);
    }

    // ─── executeOwnershipRecovery ─────────────────────────────────────────────

    function test_executeOwnershipRecovery_validSignatures_createsRequest() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        bytes[] memory sigs = _ownershipSigs3(newOwner);

        uint256 expectedAfter = block.timestamp + recovery.TIMELOCK_PERIOD();
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);

        (, address target, uint256 execAfter, bool executed,) = recovery.getRecoveryStatus(address(vault));
        assertEq(target, newOwner);
        assertEq(execAfter, expectedAfter);
        assertFalse(executed);
    }

    function test_executeOwnershipRecovery_insufficientSignatures_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        uint256 nonce = recovery.nonces(address(vault));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signOwnership(keyA, newOwner, nonce);
        sigs[1] = _signOwnership(keyB, newOwner, nonce);

        vm.expectRevert(SocialRecoveryModule.InsufficientSignatures.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
    }

    function test_executeOwnershipRecovery_duplicateSigner_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        uint256 nonce = recovery.nonces(address(vault));
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, newOwner, nonce);
        sigs[1] = _signOwnership(keyB, newOwner, nonce);
        sigs[2] = _signOwnership(keyA, newOwner, nonce); // duplicate A

        vm.expectRevert(SocialRecoveryModule.DuplicateSigner.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
    }

    function test_executeOwnershipRecovery_nonGuardianSigner_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        uint256 nonce = recovery.nonces(address(vault));
        uint256 rogueKey = 0xDEAD;
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, newOwner, nonce);
        sigs[1] = _signOwnership(keyB, newOwner, nonce);
        sigs[2] = _signOwnership(rogueKey, newOwner, nonce); // not a guardian

        vm.expectRevert(SocialRecoveryModule.NotGuardian.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
    }

    function test_executeOwnershipRecovery_noConfig_reverts() public {
        address newOwner = makeAddr("newOwner");
        uint256 nonce = recovery.nonces(address(vault));
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, newOwner, nonce);
        sigs[1] = _signOwnership(keyB, newOwner, nonce);
        sigs[2] = _signOwnership(keyC, newOwner, nonce);

        vm.expectRevert(SocialRecoveryModule.NoConfig.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
    }

    function test_executeOwnershipRecovery_zeroNewOwner_reverts() public {
        _setConfig3of5();
        bytes[] memory sigs = new bytes[](3);
        vm.expectRevert(SocialRecoveryModule.ZeroAddress.selector);
        recovery.executeOwnershipRecovery(address(vault), address(0), sigs);
    }

    function test_executeOwnershipRecovery_recoveryAlreadyActive_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        bytes[] memory sigs = _ownershipSigs3(newOwner);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);

        // Second call while first is active
        bytes[] memory sigs2 = _ownershipSigs3(newOwner);
        vm.expectRevert(SocialRecoveryModule.RecoveryAlreadyActive.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs2);
    }

    function test_executeOwnershipRecovery_afterExpiry_allowsNewRequest() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        bytes[] memory sigs = _ownershipSigs3(newOwner);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);

        // Warp past 7-day expiry window (48h delay + 7 days)
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD() + recovery.MAX_RECOVERY_DURATION() + 1);

        // Should be allowed to start fresh recovery (old one expired)
        bytes[] memory sigs2 = _ownershipSigs3(newOwner);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs2);
        (, address target,,,) = recovery.getRecoveryStatus(address(vault));
        assertEq(target, newOwner);
    }

    // ─── executeGuardianRecovery ──────────────────────────────────────────────

    function test_executeGuardianRecovery_validSignatures_createsRequest() public {
        _setConfig3of5();
        address newGuardian = makeAddr("newGuardian");
        bytes[] memory sigs = _guardianSigs3(newGuardian);

        recovery.executeGuardianRecovery(address(vault), newGuardian, sigs);

        (SocialRecoveryModule.RecoveryAction action, address target,,, ) = recovery.getRecoveryStatus(address(vault));
        assertEq(uint8(action), uint8(SocialRecoveryModule.RecoveryAction.SET_GUARDIAN));
        assertEq(target, newGuardian);
    }

    function test_executeGuardianRecovery_insufficientSignatures_reverts() public {
        _setConfig3of5();
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = recovery.nonces(address(vault));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signGuardian(keyA, newGuardian, nonce);
        sigs[1] = _signGuardian(keyB, newGuardian, nonce);

        vm.expectRevert(SocialRecoveryModule.InsufficientSignatures.selector);
        recovery.executeGuardianRecovery(address(vault), newGuardian, sigs);
    }

    function test_executeGuardianRecovery_duplicateSigner_reverts() public {
        _setConfig3of5();
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = recovery.nonces(address(vault));
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signGuardian(keyA, newGuardian, nonce);
        sigs[1] = _signGuardian(keyB, newGuardian, nonce);
        sigs[2] = _signGuardian(keyA, newGuardian, nonce); // duplicate

        vm.expectRevert(SocialRecoveryModule.DuplicateSigner.selector);
        recovery.executeGuardianRecovery(address(vault), newGuardian, sigs);
    }

    function test_executeGuardianRecovery_ownershipSigRejected() public {
        // Ownership signature must not be usable for guardian recovery (different typehash)
        _setConfig3of5();
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = recovery.nonces(address(vault));
        // Sign using OWNERSHIP typehash but submit to guardian recovery
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, newGuardian, nonce);
        sigs[1] = _signOwnership(keyB, newGuardian, nonce);
        sigs[2] = _signOwnership(keyC, newGuardian, nonce);

        vm.expectRevert(SocialRecoveryModule.NotGuardian.selector);
        recovery.executeGuardianRecovery(address(vault), newGuardian, sigs);
    }

    // ─── finalizeRecovery ─────────────────────────────────────────────────────

    function test_finalizeRecovery_ownershipBeforeDelay_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        vm.expectRevert(SocialRecoveryModule.DelayNotElapsed.selector);
        recovery.finalizeRecovery(address(vault));
    }

    function test_finalizeRecovery_ownershipAfterDelay_transfersOwnership() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));

        assertEq(vault.owner(), newOwner, "Ownership must transfer");
    }

    function test_finalizeRecovery_guardianAfterDelay_updatesGuardian() public {
        _setConfig3of5();
        address newGuardian = makeAddr("newGuardian");
        recovery.executeGuardianRecovery(address(vault), newGuardian, _guardianSigs3(newGuardian));

        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));

        assertEq(vault.lastGuardianSet(), newGuardian, "Guardian must update");
    }

    function test_finalizeRecovery_noActiveRecovery_reverts() public {
        vm.expectRevert(SocialRecoveryModule.RecoveryNotActive.selector);
        recovery.finalizeRecovery(address(vault));
    }

    function test_finalizeRecovery_alreadyExecuted_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));

        vm.expectRevert(SocialRecoveryModule.RecoveryNotActive.selector);
        recovery.finalizeRecovery(address(vault));
    }

    function test_finalizeRecovery_afterExpiry_reverts() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        // Warp past the 7-day expiry window
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD() + recovery.MAX_RECOVERY_DURATION() + 1);

        vm.expectRevert(SocialRecoveryModule.RecoveryExpired.selector);
        recovery.finalizeRecovery(address(vault));
    }

    function test_finalizeRecovery_nonceIncrements() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        assertEq(recovery.nonces(address(vault)), 0);
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));
        assertEq(recovery.nonces(address(vault)), 1, "Nonce must increment after finalization");
    }

    function test_finalizeRecovery_calledByAnyone() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));

        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        recovery.finalizeRecovery(address(vault)); // any address can finalize

        assertEq(vault.owner(), newOwner);
    }

    // ─── Replay protection ────────────────────────────────────────────────────

    function test_replayProtection_oldSignaturesInvalidAfterNonceIncrement() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");

        // Collect signatures at nonce=0
        bytes[] memory sigs = _ownershipSigs3(newOwner);

        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault)); // nonce becomes 1

        // Attempt to reuse old signatures (signed for nonce=0) with nonce now at 1
        vm.expectRevert(SocialRecoveryModule.NotGuardian.selector);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
    }

    function test_replayProtection_ownershipSigNotValidForGuardianAction() public {
        _setConfig3of5();
        address target = makeAddr("target");
        uint256 nonce = recovery.nonces(address(vault));

        // Sign ownership recovery for `target`
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signOwnership(keyA, target, nonce);
        sigs[1] = _signOwnership(keyB, target, nonce);
        sigs[2] = _signOwnership(keyC, target, nonce);

        // These signatures cannot be used for guardian recovery (different typehash)
        vm.expectRevert(SocialRecoveryModule.NotGuardian.selector);
        recovery.executeGuardianRecovery(address(vault), target, sigs);
    }

    // ─── Integration flows ────────────────────────────────────────────────────

    function test_integration_fullOwnershipRecoveryFlow() public {
        _setConfig3of5();

        address originalOwner = vault.owner();
        address newOwner      = makeAddr("newOwner");
        assertEq(originalOwner, vaultOwner);

        // Step 1: Collect guardian signatures (off-chain)
        bytes[] memory sigs = _ownershipSigs3(newOwner);

        // Step 2: Submit in single transaction (starts 48h delay)
        uint256 execAfter = recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);
        assertEq(vault.owner(), originalOwner, "Owner must not change yet");

        // Step 3: 48h passes
        vm.warp(execAfter);

        // Step 4: Finalize
        recovery.finalizeRecovery(address(vault));
        assertEq(vault.owner(), newOwner, "Owner must be updated");
        assertEq(recovery.nonces(address(vault)), 1);
    }

    function test_integration_fullGuardianRecoveryFlow() public {
        _setConfig3of5();

        address newGuardian = makeAddr("newGuardian");

        // Step 1: Collect guardian signatures (off-chain)
        bytes[] memory sigs = _guardianSigs3(newGuardian);

        // Step 2: Submit
        uint256 execAfter = recovery.executeGuardianRecovery(address(vault), newGuardian, sigs);
        assertEq(vault.lastGuardianSet(), address(0), "Guardian must not change yet");

        // Step 3: 48h passes
        vm.warp(execAfter);

        // Step 4: Finalize
        recovery.finalizeRecovery(address(vault));
        assertEq(vault.lastGuardianSet(), newGuardian, "Guardian must be updated");
    }

    function test_integration_sequentialOwnershipThenGuardianRecovery() public {
        _setConfig3of5();

        // ── Recovery 1: Transfer ownership ──────────────────────────────────
        address newOwner = makeAddr("newOwner");
        recovery.executeOwnershipRecovery(address(vault), newOwner, _ownershipSigs3(newOwner));
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));
        assertEq(vault.owner(), newOwner);
        assertEq(recovery.nonces(address(vault)), 1);

        // ── Recovery 2: Change guardian (nonce is now 1) ─────────────────────
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = recovery.nonces(address(vault)); // = 1

        bytes[] memory sigs2 = new bytes[](3);
        sigs2[0] = _signGuardian(keyA, newGuardian, nonce);
        sigs2[1] = _signGuardian(keyB, newGuardian, nonce);
        sigs2[2] = _signGuardian(keyC, newGuardian, nonce);

        recovery.executeGuardianRecovery(address(vault), newGuardian, sigs2);
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD());
        recovery.finalizeRecovery(address(vault));

        assertEq(vault.lastGuardianSet(), newGuardian);
        assertEq(recovery.nonces(address(vault)), 2);
    }

    function test_integration_expiredRecoveryAllowsNewOne() public {
        _setConfig3of5();
        address newOwner = makeAddr("newOwner");

        // Initiate recovery
        bytes[] memory sigs = _ownershipSigs3(newOwner);
        recovery.executeOwnershipRecovery(address(vault), newOwner, sigs);

        // Let it expire without finalizing
        vm.warp(block.timestamp + recovery.TIMELOCK_PERIOD() + recovery.MAX_RECOVERY_DURATION() + 1);

        (, , , , bool expired) = recovery.getRecoveryStatus(address(vault));
        assertTrue(expired, "Recovery should be expired");

        // Start fresh with same nonce (no increment happened)
        address newOwner2 = makeAddr("newOwner2");
        bytes[] memory sigs2 = _ownershipSigs3(newOwner2); // still nonce=0
        recovery.executeOwnershipRecovery(address(vault), newOwner2, sigs2);

        (, address target, , , ) = recovery.getRecoveryStatus(address(vault));
        assertEq(target, newOwner2, "New recovery target should be stored");
    }
}
