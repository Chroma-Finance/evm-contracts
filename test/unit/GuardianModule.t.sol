// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {GuardianModule} from "../../src/modules/GuardianModule.sol";
import {IGuardian} from "../../src/interfaces/IGuardian.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";

// ─── Minimal vault stub for unit tests ──────────────────────────────────────

contract MockVault {
    address public owner;
    constructor(address owner_) { owner = owner_; }
}

// ─── Minimal ERC-20 for integration tests ────────────────────────────────────

contract MockERC20 {
    string public name     = "Mock USDC";
    string public symbol   = "USDC";
    uint8  public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount; balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ─── Unit tests for GuardianModule ───────────────────────────────────────────

contract GuardianModuleUnitTest is Test {
    event GuardianSet(address indexed vault, address indexed guardian);

    GuardianModule internal gm;

    uint256 internal guardianKey = 0xBEEF;
    address internal guardian;
    address internal vaultOwner = makeAddr("vaultOwner");
    MockVault internal mockVault;

    bytes32 internal constant TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        gm = new GuardianModule();
        guardian = vm.addr(guardianKey);
        mockVault = new MockVault(vaultOwner);

        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), guardian);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _sign(
        address vault_,
        address owner_,
        uint256 amount_,
        address recipient_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, vault_, owner_, amount_, recipient_, nonce_, deadline_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── setGuardian ─────────────────────────────────────────────────────────

    function test_setGuardian_onlyVaultOwner() public {
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        gm.setGuardian(address(mockVault), makeAddr("rogue"));
    }

    function test_setGuardian_emitsEvent() public {
        address newGuardian = makeAddr("newGuardian");
        vm.expectEmit(true, true, false, false, address(gm));
        emit GuardianSet(address(mockVault), newGuardian);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian);
    }

    function test_setGuardian_disableByZeroAddress() public {
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), address(0));
        assertEq(gm.guardians(address(mockVault)), address(0));
    }

    // ─── validateWithdrawal – no guardian set (auto-approve) ─────────────────

    function test_validateWithdrawal_noGuardian_autoApprove() public {
        MockVault vault2 = new MockVault(vaultOwner);
        // no guardian set → auto-approve
        bool ok = gm.validateWithdrawal(
            address(vault2), vaultOwner, 100e6, vaultOwner, block.timestamp, new bytes(0)
        );
        assertTrue(ok, "Should auto-approve when no guardian set");
    }

    // ─── validateWithdrawal – valid signature ────────────────────────────────

    function test_validateWithdrawal_validSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline);

        bool ok = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertTrue(ok, "Valid guardian signature must be accepted");
    }

    function test_validateWithdrawal_validSignature_incrementsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline);

        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0);
        gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 1);
    }

    // ─── validateWithdrawal – invalid signature ───────────────────────────────

    function test_validateWithdrawal_wrongSigner_returnsFalse() public {
        uint256 deadline = block.timestamp + 1 hours;
        // sign with a different key
        uint256 rogueKey = 0xDEAD;
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bool ok = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertFalse(ok, "Wrong signer must be rejected");
    }

    function test_validateWithdrawal_wrongSigner_doesNotIncrementNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 rogueKey = 0xDEAD;
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0, "Nonce must not change on failed validation");
    }

    // ─── validateWithdrawal – expired deadline ────────────────────────────────

    function test_validateWithdrawal_expiredDeadline_returnsFalse() public {
        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory sig = _sign(address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline);

        bool ok = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertFalse(ok, "Expired deadline must be rejected");
    }

    // ─── validateWithdrawal – replay attack ──────────────────────────────────

    function test_validateWithdrawal_replayPrevented() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline);

        bool first = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertTrue(first, "First call must succeed");

        // Replay with the same signature (nonce is now 1, but sig was for nonce 0)
        bool second = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertFalse(second, "Replayed signature must be rejected");
    }

    // ─── validateWithdrawal – cross-vault protection ──────────────────────────

    function test_validateWithdrawal_crossVaultProtection() public {
        // Create a second vault whose guardian is also set
        MockVault vault2 = new MockVault(vaultOwner);
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault2), guardian);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign for vault2 but try to use for mockVault
        bytes memory sig = _sign(address(vault2), vaultOwner, 100e6, vaultOwner, 0, deadline);

        bool ok = gm.validateWithdrawal(address(mockVault), vaultOwner, 100e6, vaultOwner, deadline, sig);
        assertFalse(ok, "Signature for vault2 must not be usable for mockVault");
    }

    // ─── validateWithdrawal – amount tampering ────────────────────────────────

    function test_validateWithdrawal_amountTampering_returnsFalse() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(mockVault), vaultOwner, 100e6, vaultOwner, 0, deadline);

        // Try to withdraw a different amount than what was signed
        bool ok = gm.validateWithdrawal(address(mockVault), vaultOwner, 999e6, vaultOwner, deadline, sig);
        assertFalse(ok, "Modified amount must be rejected");
    }

    // ─── getNonce / getDomainSeparator ───────────────────────────────────────

    function test_getNonce_initiallyZero() public view {
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0);
    }

    function test_getDomainSeparator_nonZero() public view {
        assertTrue(gm.getDomainSeparator() != bytes32(0));
    }
}

// ─── Integration tests: PortfolioVault + GuardianModule ──────────────────────

contract GuardianIntegrationTest is Test {
    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    MockERC20        internal usdc;
    GuardianModule   internal gm;

    uint256 internal guardianKey = 0xC0FFEE;
    address internal guardian;
    address internal user = makeAddr("user");
    address internal feeRecipient = makeAddr("feeRecipient");

    address internal WBTC = makeAddr("WBTC");
    address internal WETH = makeAddr("WETH");
    address internal FEED_WBTC = makeAddr("feed_wbtc");
    address internal FEED_WETH = makeAddr("feed_weth");

    bytes32 internal constant TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    PortfolioVault internal vault;

    function setUp() public {
        guardian = vm.addr(guardianKey);
        usdc     = new MockERC20();
        registry = new RiskTierRegistry();

        address[] memory assets  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        assets[0] = WBTC;  weights[0] = 5_000; feeds[0] = FEED_WBTC;
        assets[1] = WETH;  weights[1] = 5_000; feeds[1] = FEED_WETH;
        registry.createTier(0, "Low Risk", assets, weights, feeds);

        factory = new VaultFactory(address(usdc), address(registry), feeRecipient);
        gm = factory.guardianModule();

        vm.prank(user);
        vault = PortfolioVault(factory.createVault(0, false));

        // Vault has guardianModule set but no guardian registered for it yet.
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _depositUsdc(uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _sign(
        address vault_,
        address owner_,
        uint256 amount_,
        address recipient_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, vault_, owner_, amount_, recipient_, nonce_, deadline_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── No guardian registered → backward-compatible ────────────────────────

    function test_withdraw_noGuardianRegistered_succeeds() public {
        // guardianModule is set on vault but no guardian address registered for this vault
        _depositUsdc(1_000e6);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.withdraw(1_000e6, user, user);
        assertEq(usdc.balanceOf(user), balBefore + 1_000e6);
    }

    function test_withdrawAll_noGuardianRegistered_succeeds() public {
        _depositUsdc(1_000e6);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.withdrawAll();
        assertGt(usdc.balanceOf(user), balBefore, "Should receive USDC back");
    }

    // ─── Guardian registered → signature required ────────────────────────────

    function test_withdraw_withGuardian_validSignature_succeeds() public {
        // Register guardian for this vault
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, 1_000e6, user, 0, deadline);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.withdraw(1_000e6, user, user, deadline, sig);
        assertEq(usdc.balanceOf(user), balBefore + 1_000e6);
    }

    function test_withdraw_withGuardian_validSignature_incrementsNonce() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, 500e6, user, 0, deadline);

        assertEq(gm.getNonce(address(vault), user), 0);
        vm.prank(user);
        vault.withdraw(500e6, user, user, deadline, sig);
        assertEq(gm.getNonce(address(vault), user), 1);
    }

    function test_withdraw_withGuardian_invalidSignature_reverts() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with wrong key
        uint256 rogueKey = 0xDEAD;
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, address(vault), user, 1_000e6, user, 0, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(1_000e6, user, user, deadline, sig);
    }

    function test_withdraw_withGuardian_expiredSignature_reverts() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(address(vault), user, 1_000e6, user, 0, deadline);

        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(1_000e6, user, user, deadline, sig);
    }

    function test_withdraw_withGuardian_replayPrevented() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, 500e6, user, 0, deadline);

        // First withdrawal succeeds
        vm.prank(user);
        vault.withdraw(500e6, user, user, deadline, sig);

        // Replay attempt reverts (nonce is now 1, sig was for nonce 0)
        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(500e6, user, user, deadline, sig);
    }

    // ─── withdrawAll with guardian ────────────────────────────────────────────

    function test_withdrawAll_withGuardian_validSignature_succeeds() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 previewedAssets = vault.previewRedeem(vault.balanceOf(user));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, previewedAssets, user, 0, deadline);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.withdrawAll(deadline, sig);
        assertGt(usdc.balanceOf(user), balBefore);
    }

    function test_withdrawAll_withGuardian_invalidSignature_reverts() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian);

        _depositUsdc(1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        // Pass empty signature → wrong signer
        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdrawAll(deadline, new bytes(0));
    }

    // ─── Backward-compat overloads ────────────────────────────────────────────

    function test_backwardCompatOverload_withdraw_noGuardian() public {
        _depositUsdc(1_000e6);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        // 3-param overload uses block.timestamp deadline + empty sig → auto-approved
        vault.withdraw(1_000e6, user, user);
        assertEq(usdc.balanceOf(user), balBefore + 1_000e6);
    }

    function test_backwardCompatOverload_redeem_noGuardian() public {
        _depositUsdc(1_000e6);

        uint256 shares = vault.balanceOf(user);
        assertGt(shares, 0);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares, user, user);
        assertGt(usdc.balanceOf(user), balBefore);
    }

    // ─── Factory exposes guardian module ─────────────────────────────────────

    function test_factory_getGuardianModule() public view {
        assertEq(factory.getGuardianModule(), address(gm));
    }

    function test_factory_vaultHasGuardianModuleSet() public view {
        assertEq(vault.guardianModule(), address(gm));
    }
}
