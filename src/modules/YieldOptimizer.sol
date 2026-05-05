// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title YieldOptimizer
 * @notice Optional boost module that deploys idle vault assets into external yield
 *         protocols (Aave lending, Uniswap V3 LP positions) and auto-compounds rewards.
 *
 * @dev TODO (Phase 3): Implement full yield optimization.
 *      Planned features:
 *      - Deploy denomination asset to Aave V3 for lending yield
 *      - Deploy token pairs to Uniswap V3 LP positions (concentrated liquidity)
 *      - Auto-harvest and compound Aave rewards and LP fees
 *      - Charge boost fee: 15% of generated yield, forwarded to {FeeManager}
 *      - Emergency withdraw: pull all deployed assets back to vault
 *      - Integration: VaultFactory registers vaults with YieldOptimizer on createVault(enableBoost=true)
 */
contract YieldOptimizer {
    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Factory that deployed this optimizer.
    address public immutable factory;

    /// @notice Boost fee charged on generated yield in basis points (15%).
    uint256 public constant BOOST_FEE_BPS = 1_500;

    // ─── Events ──────────────────────────────────────────────────────────────

    event VaultRegistered(address indexed vault);
    event YieldHarvested(address indexed vault, address indexed token, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error NotImplemented();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address factory_) {
        factory = factory_;
    }

    // ─── Stub functions (Phase 3) ─────────────────────────────────────────────

    /// @notice Registers a vault to receive yield optimization. Called by VaultFactory.
    function registerVault(address) external pure {
        // TODO: Phase 3 — track vault, deploy initial allocation to Aave/Uniswap V3.
        revert NotImplemented();
    }

    /// @notice Harvests and compounds yield for a registered vault.
    function harvest(address) external pure {
        // TODO: Phase 3 — collect Aave rewards + LP fees, swap to denomination asset, re-deploy.
        revert NotImplemented();
    }

    /// @notice Withdraws all deployed assets back to the vault (emergency exit).
    function emergencyWithdraw(address) external pure {
        // TODO: Phase 3 — redeem Aave aTokens and remove Uniswap V3 LP positions.
        revert NotImplemented();
    }
}
