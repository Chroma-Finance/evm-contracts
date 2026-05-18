// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {GuardianModule} from "../../src/modules/GuardianModule.sol";
import {IGuardian} from "../../src/interfaces/IGuardian.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {PortfolioVault} from "../../src/core/PortfolioVault.sol";
import {RiskTierRegistry} from "../../src/utils/RiskTierRegistry.sol";
import {IChromaSwapRouter} from "../../src/interfaces/ISwapRouter.sol";

// ─── Minimal vault stub for unit tests ───────────────────────────────────────

contract MockVault {
    address public owner;
    constructor(address owner_) { owner = owner_; }
}

// ─── ERC-20 mock ─────────────────────────────────────────────────────────────

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

// ─── Mock Chainlink aggregator ($1 price) ─────────────────────────────────────

contract MockAggregator {
    uint80 public roundId = 1;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, 1e8, 0, block.timestamp, roundId);
    }
}

// ─── Mock SwapRouter ─────────────────────────────────────────────────────────

contract MockSwapRouter is IChromaSwapRouter {
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

// ─── Unit tests for GuardianModule ───────────────────────────────────────────

contract GuardianModuleUnitTest is Test {
    event GuardianSet(address indexed vault, address indexed guardian);

    GuardianModule internal gm;

    uint256 internal guardianKey = 0xBEEF;
    address internal guardian;
    address internal vaultOwner = makeAddr("vaultOwner");
    MockVault internal mockVault;

    bytes32 internal constant WITHDRAWAL_TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        gm = new GuardianModule();
        guardian = vm.addr(guardianKey);
        mockVault = new MockVault(vaultOwner);

        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), guardian, new bytes(0));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _signWithdrawal(
        address vault_,
        address owner_,
        uint256 amount_,
        address recipient_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            WITHDRAWAL_TYPEHASH, vault_, owner_, amount_, recipient_, nonce_, deadline_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signGuardianUpdate(address vault_, address newGuardian_, uint256 nonce_)
        internal view returns (bytes memory)
    {
        return _signGuardianUpdateWith(vault_, newGuardian_, nonce_, guardianKey);
    }

    function _signGuardianUpdateWith(address vault_, address newGuardian_, uint256 nonce_, uint256 key_)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            gm.GUARDIAN_UPDATE_TYPEHASH(), vault_, newGuardian_, nonce_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", gm.getDomainSeparator(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key_, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── setGuardian – initial set ────────────────────────────────────────────

    function test_setGuardian_initialSet_onlyOwner_reverts() public {
        MockVault freshVault = new MockVault(vaultOwner);
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        gm.setGuardian(address(freshVault), guardian, new bytes(0));
    }

    function test_setGuardian_initialSet_emitsEvent() public {
        MockVault freshVault = new MockVault(vaultOwner);
        address newGuardian = makeAddr("newGuardian");
        vm.expectEmit(true, true, false, false, address(gm));
        emit GuardianSet(address(freshVault), newGuardian);
        vm.prank(vaultOwner);
        gm.setGuardian(address(freshVault), newGuardian, new bytes(0));
    }

    // ─── setGuardian – owner-initiated change with guardian sig ───────────────

    function test_setGuardian_alreadySet_noSignature_reverts() public {
        vm.expectRevert(GuardianModule.InvalidSignature.selector);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), makeAddr("newGuardian"), new bytes(0));
    }

    function test_setGuardian_nonOwner_alreadySet_reverts() public {
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        gm.setGuardian(address(mockVault), makeAddr("rogue"), new bytes(0));
    }

    function test_setGuardian_changeWithGuardianSignature_succeeds() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), newGuardian, nonce);

        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);

        assertEq(gm.guardians(address(mockVault)), newGuardian);
    }

    function test_setGuardian_changeWithGuardianSignature_emitsEvent() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), newGuardian, nonce);

        vm.expectEmit(true, true, false, false, address(gm));
        emit GuardianSet(address(mockVault), newGuardian);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);
    }

    function test_setGuardian_changeWithGuardianSignature_incrementsNonce() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), newGuardian, nonce);

        assertEq(gm.guardianChangeNonces(address(mockVault)), 0);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);
        assertEq(gm.guardianChangeNonces(address(mockVault)), 1);
    }

    function test_setGuardian_invalidSignature_reverts() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdateWith(address(mockVault), newGuardian, nonce, 0xDEAD);

        vm.expectRevert(GuardianModule.InvalidSignature.selector);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);
    }

    function test_setGuardian_replayAttack_reverts() public {
        address newGuardian = makeAddr("newGuardian");
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), newGuardian, nonce);

        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);

        vm.expectRevert(GuardianModule.InvalidSignature.selector);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), newGuardian, sig);
    }

    // ─── setGuardian – renounce ───────────────────────────────────────────────

    function test_setGuardian_renounce_withGuardianSignature_succeeds() public {
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), address(0), nonce);

        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), address(0), sig);

        assertEq(gm.guardians(address(mockVault)), address(0));
    }

    function test_setGuardian_postRenounce_ownerCanSetFreely() public {
        uint256 nonce = gm.guardianChangeNonces(address(mockVault));
        bytes memory sig = _signGuardianUpdate(address(mockVault), address(0), nonce);
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), address(0), sig);

        address freshGuardian = makeAddr("freshGuardian");
        vm.prank(vaultOwner);
        gm.setGuardian(address(mockVault), freshGuardian, new bytes(0));

        assertEq(gm.guardians(address(mockVault)), freshGuardian);
    }

    // ─── validateWithdrawal ───────────────────────────────────────────────────

    function test_validateWithdrawal_noGuardian_autoApprove() public {
        MockVault vault2 = new MockVault(vaultOwner);
        bool ok = gm.validateWithdrawal(
            address(vault2), vaultOwner, 100e8, vaultOwner, block.timestamp, new bytes(0)
        );
        assertTrue(ok);
    }

    function test_validateWithdrawal_validSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline);
        assertTrue(gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig));
    }

    function test_validateWithdrawal_validSignature_incrementsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline);

        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0);
        gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig);
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 1);
    }

    function test_validateWithdrawal_wrongSigner_returnsFalse() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(WITHDRAWAL_TYPEHASH, address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gm.getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertFalse(gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig));
    }

    function test_validateWithdrawal_wrongSigner_doesNotIncrementNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(WITHDRAWAL_TYPEHASH, address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gm.getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig);
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0);
    }

    function test_validateWithdrawal_expiredDeadline_returnsFalse() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline);
        assertFalse(gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig));
    }

    function test_validateWithdrawal_replayPrevented() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline);

        assertTrue(gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig));
        assertFalse(gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig));
    }

    function test_validateWithdrawal_crossVaultProtection() public {
        MockVault vault2 = new MockVault(vaultOwner);
        vm.prank(vaultOwner);
        gm.setGuardian(address(vault2), guardian, new bytes(0));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(address(vault2), vaultOwner, 100e8, vaultOwner, 0, deadline);

        assertFalse(
            gm.validateWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, deadline, sig),
            "Signature for vault2 must not be usable for mockVault"
        );
    }

    function test_validateWithdrawal_amountTampering_returnsFalse() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWithdrawal(address(mockVault), vaultOwner, 100e8, vaultOwner, 0, deadline);
        assertFalse(gm.validateWithdrawal(address(mockVault), vaultOwner, 999e8, vaultOwner, deadline, sig));
    }

    function test_getNonce_initiallyZero() public view {
        assertEq(gm.getNonce(address(mockVault), vaultOwner), 0);
    }

    function test_getDomainSeparator_nonZero() public view {
        assertTrue(gm.getDomainSeparator() != bytes32(0));
    }
}

// ─── Integration: PortfolioVault + GuardianModule ─────────────────────────────

contract GuardianIntegrationTest is Test {
    VaultFactory     internal factory;
    RiskTierRegistry internal registry;
    MockERC20        internal usdc;
    MockERC20        internal WBTC;
    MockERC20        internal WETH;
    GuardianModule   internal gm;
    MockSwapRouter   internal router;

    uint256 internal guardianKey = 0xC0FFEE;
    address internal guardian;
    address internal user         = makeAddr("user");
    address internal feeRecipient = makeAddr("feeRecipient");

    bytes32 internal constant TYPEHASH = keccak256(
        "WithdrawalApproval(address vault,address owner,uint256 amount,address recipient,uint256 nonce,uint256 deadline)"
    );

    PortfolioVault internal vault;

    function setUp() public {
        guardian = vm.addr(guardianKey);
        usdc     = new MockERC20("USD Coin", "USDC", 6);
        WBTC     = new MockERC20("WBTC",     "WBTC", 6);
        WETH     = new MockERC20("WETH",     "WETH", 6);
        router   = new MockSwapRouter();

        registry = new RiskTierRegistry();

        MockAggregator feedWbtc = new MockAggregator();
        MockAggregator feedWeth = new MockAggregator();

        address[] memory assets  = new address[](2);
        uint256[] memory weights = new uint256[](2);
        address[] memory feeds   = new address[](2);
        assets[0] = address(WBTC);  weights[0] = 5_000;  feeds[0] = address(feedWbtc);
        assets[1] = address(WETH);  weights[1] = 5_000;  feeds[1] = address(feedWeth);
        registry.createTier(0, "Low Risk", assets, weights, feeds);

        factory = new VaultFactory(address(router), address(registry), feeRecipient);
        gm      = factory.guardianModule();

        vm.prank(user);
        vault = PortfolioVault(factory.createVault(0, false));
    }

    // ─── Helper: deposit ─────────────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    // ─── Helper: sign ────────────────────────────────────────────────────────

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

    // ─── No guardian: withdraws freely ───────────────────────────────────────

    function test_withdraw_noGuardianRegistered_succeeds() public {
        _deposit(1_000e6);
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.withdraw(address(usdc), shares, block.timestamp, new bytes(0));
        assertEq(vault.balanceOf(user), 0);
    }

    // ─── Guardian registered: signature required ──────────────────────────────

    function test_withdraw_withGuardian_validSignature_succeeds() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(1_000e6);

        uint256 shares   = vault.balanceOf(user);
        uint256 usdValue = vault.totalAssets() * shares / vault.totalSupply();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, usdValue, user, 0, deadline);

        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, sig);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_withdraw_withGuardian_validSignature_incrementsNonce() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(1_000e6);

        uint256 shares   = vault.balanceOf(user) / 2;
        uint256 usdValue = (vault.totalAssets() + 1) * shares / (vault.totalSupply() + 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, usdValue, user, 0, deadline);

        assertEq(gm.getNonce(address(vault), user), 0);
        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, sig);
        assertEq(gm.getNonce(address(vault), user), 1);
    }

    function test_withdraw_withGuardian_invalidSignature_reverts() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(1_000e6);

        uint256 shares   = vault.balanceOf(user);
        uint256 usdValue = (vault.totalAssets() + 1) * shares / (vault.totalSupply() + 1);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(abi.encode(TYPEHASH, address(vault), user, usdValue, user, 0, deadline));
        bytes32 digest     = keccak256(abi.encodePacked("\x19\x01", gm.getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, badSig);
    }

    function test_withdraw_withGuardian_expiredSignature_reverts() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(1_000e6);

        uint256 shares   = vault.balanceOf(user);
        uint256 usdValue = (vault.totalAssets() + 1) * shares / (vault.totalSupply() + 1);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(address(vault), user, usdValue, user, 0, deadline);

        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, sig);
    }

    function test_withdraw_withGuardian_replayPrevented() public {
        vm.prank(user);
        gm.setGuardian(address(vault), guardian, new bytes(0));

        _deposit(1_000e6);

        uint256 shares   = vault.balanceOf(user) / 2;
        uint256 usdValue = (vault.totalAssets() + 1) * shares / (vault.totalSupply() + 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(vault), user, usdValue, user, 0, deadline);

        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, sig);

        vm.expectRevert(PortfolioVault.GuardianApprovalRequired.selector);
        vm.prank(user);
        vault.withdraw(address(usdc), shares, deadline, sig);
    }

    // ─── Factory exposes guardian module ─────────────────────────────────────

    function test_factory_getGuardianModule() public view {
        assertEq(factory.getGuardianModule(), address(gm));
    }

    function test_factory_vaultHasGuardianModuleSet() public view {
        assertEq(vault.guardianModule(), address(gm));
    }
}
