// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title EventNotifier
 * @notice Centralized hub for all financial events emitted by Chroma Finance vaults.
 *
 *         Vaults call this contract instead of emitting events directly, giving indexers
 *         and subgraphs a single address to watch for TVL, deposits, withdrawals, and fees
 *         across the entire protocol.
 *
 *         Security events (guardian approvals, recovery, ownership) remain in their
 *         respective modules because auditors need them close to the logic.
 *
 * Access control:
 *   - Owner (protocol multi-sig) can authorize or revoke emitter addresses.
 *   - VaultFactory authorizes itself and each new vault on creation.
 *   - Only authorized addresses can call emit* functions.
 */
contract EventNotifier is Ownable {

    // ─── State ───────────────────────────────────────────────────────────────

    mapping(address => bool) public authorized;

    // ─── Financial events ────────────────────────────────────────────────────

    event Deposited(
        address indexed user,
        address indexed vault,
        uint8 indexed tier,
        uint256 assets,
        uint256 shares,
        uint256 vaultTotalAssets,
        uint256 timestamp
    );

    event Withdrawn(
        address indexed user,
        address indexed vault,
        uint8 indexed tier,
        uint256 assets,
        uint256 shares,
        uint256 vaultTotalAssets,
        uint256 timestamp
    );

    event ManagementFeeAccrued(
        address indexed vault,
        uint8 indexed tier,
        uint256 feeShares,
        uint256 vaultTotalAssets,
        uint256 timestamp
    );

    event PerformanceFeeCharged(
        address indexed vault,
        uint8 indexed tier,
        address indexed user,
        uint256 feeAssets,
        uint256 vaultTotalAssets,
        uint256 timestamp
    );

    event BoostFeeCharged(
        address indexed vault,
        uint8 indexed tier,
        uint256 feeAmount,
        uint256 vaultTotalAssets,
        uint256 timestamp
    );

    event VaultCreated(
        address indexed user,
        address indexed vault,
        uint8 indexed tier,
        uint256 timestamp
    );

    // ─── Admin events ────────────────────────────────────────────────────────

    event EmitterAuthorized(address indexed emitter);
    event EmitterRevoked(address indexed emitter);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address owner_) Ownable(owner_) {}

    // ─── Access control ──────────────────────────────────────────────────────

    function authorize(address emitter) external onlyOwner {
        if (emitter == address(0)) revert ZeroAddress();
        authorized[emitter] = true;
        emit EmitterAuthorized(emitter);
    }

    function revoke(address emitter) external onlyOwner {
        authorized[emitter] = false;
        emit EmitterRevoked(emitter);
    }

    // ─── Emit functions ──────────────────────────────────────────────────────

    function emitDeposit(
        address user,
        address vault,
        uint8 tier,
        uint256 assets,
        uint256 shares,
        uint256 vaultTotalAssets
    ) external onlyAuthorized {
        emit Deposited(user, vault, tier, assets, shares, vaultTotalAssets, block.timestamp);
    }

    function emitWithdrawal(
        address user,
        address vault,
        uint8 tier,
        uint256 assets,
        uint256 shares,
        uint256 vaultTotalAssets
    ) external onlyAuthorized {
        emit Withdrawn(user, vault, tier, assets, shares, vaultTotalAssets, block.timestamp);
    }

    function emitManagementFee(
        address vault,
        uint8 tier,
        uint256 feeShares,
        uint256 vaultTotalAssets
    ) external onlyAuthorized {
        emit ManagementFeeAccrued(vault, tier, feeShares, vaultTotalAssets, block.timestamp);
    }

    function emitPerformanceFee(
        address vault,
        uint8 tier,
        address user,
        uint256 feeAssets,
        uint256 vaultTotalAssets
    ) external onlyAuthorized {
        emit PerformanceFeeCharged(vault, tier, user, feeAssets, vaultTotalAssets, block.timestamp);
    }

    function emitBoostFee(
        address vault,
        uint8 tier,
        uint256 feeAmount,
        uint256 vaultTotalAssets
    ) external onlyAuthorized {
        emit BoostFeeCharged(vault, tier, feeAmount, vaultTotalAssets, block.timestamp);
    }

    function emitVaultCreated(
        address user,
        address vault,
        uint8 tier
    ) external onlyAuthorized {
        emit VaultCreated(user, vault, tier, block.timestamp);
    }
}
