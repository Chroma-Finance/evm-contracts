// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RiskTierRegistry
 * @notice Stores portfolio tier definitions (asset lists and target allocations) used by
 *         {VaultFactory} when initialising new {PortfolioVault}s.
 *
 *         Three predefined tiers (IDs 0–2) are populated via {createTier} during deployment.
 *         All weights must sum to exactly 10 000 basis points (100%).
 *
 *         Planned allocations (actual token addresses set in deploy script):
 *
 *         Tier 0 — Low Risk
 *           40% WBTC  |  30% XAUT  |  30% PAXG
 *
 *         Tier 1 — Medium Risk
 *           25% WBTC  |  25% WETH  |  20% XAUT  |  20% PAXG  |  10% stETH
 *
 *         Tier 2 — High Risk
 *           25% WBTC  |  25% WETH  |  15% stETH  |  10% XAUT  |  10% PAXG  |  15% Alts
 *
 *         "Alts" in Tier 2 represents a basket slot; the specific token address for
 *         the alts position is configured at deployment time.
 */
contract RiskTierRegistry is Ownable {
    // ─── Types ───────────────────────────────────────────────────────────────

    struct RiskTier {
        string    name;
        address[] assets;
        uint256[] weights; // basis points; must sum to BPS_DENOMINATOR
        bool      active;
    }

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Tier ID → tier definition.
    mapping(uint8 => RiskTier) private _tiers;

    /// @notice Highest tier ID that has been created (used for off-chain enumeration).
    uint8 public tierCount;

    // ─── Events ──────────────────────────────────────────────────────────────

    event TierCreated(uint8 indexed tierId, string name, uint256 assetCount);
    event TierUpdated(uint8 indexed tierId, uint256 assetCount);
    event TierDeactivated(uint8 indexed tierId);
    event TierActivated(uint8 indexed tierId);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error TierAlreadyExists();
    error TierNotFound();
    error ZeroAddress();
    error InvalidWeights();
    error LengthMismatch();
    error EmptyAssets();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Creates a new risk tier.
     * @dev Each tier ID can only be created once; use {updateTier} to modify an existing tier.
     *      Tiers are created as active; deactivate explicitly if needed.
     * @param id      Tier identifier (0 = Low, 1 = Medium, 2 = High by convention).
     * @param name_   Human-readable name (e.g., "Low Risk").
     * @param assets_ Asset token addresses (no zero addresses, no duplicates).
     * @param weights_ Allocation in basis points per asset; must sum to 10 000.
     */
    function createTier(
        uint8 id,
        string calldata name_,
        address[] calldata assets_,
        uint256[] calldata weights_
    ) external onlyOwner {
        if (_tiers[id].assets.length != 0) revert TierAlreadyExists();
        _validateInputs(assets_, weights_);

        RiskTier storage tier = _tiers[id];
        tier.name   = name_;
        tier.active = true;

        for (uint256 i = 0; i < assets_.length; i++) {
            tier.assets.push(assets_[i]);
            tier.weights.push(weights_[i]);
        }

        if (id >= tierCount) tierCount = id + 1;
        emit TierCreated(id, name_, assets_.length);
    }

    /**
     * @notice Replaces the asset list and weights for an existing tier.
     * @dev Name and active state are preserved; only allocation is updated.
     * @param id      Tier ID to update.
     * @param assets_ New asset token addresses.
     * @param weights_ New allocation in basis points; must sum to 10 000.
     */
    function updateTier(
        uint8 id,
        address[] calldata assets_,
        uint256[] calldata weights_
    ) external onlyOwner {
        if (_tiers[id].assets.length == 0) revert TierNotFound();
        _validateInputs(assets_, weights_);

        RiskTier storage tier = _tiers[id];
        delete tier.assets;
        delete tier.weights;

        for (uint256 i = 0; i < assets_.length; i++) {
            tier.assets.push(assets_[i]);
            tier.weights.push(weights_[i]);
        }

        emit TierUpdated(id, assets_.length);
    }

    /// @notice Deactivates a tier so it cannot be used for new vault creation.
    function deactivateTier(uint8 id) external onlyOwner {
        if (_tiers[id].assets.length == 0) revert TierNotFound();
        _tiers[id].active = false;
        emit TierDeactivated(id);
    }

    /// @notice Re-activates a previously deactivated tier.
    function activateTier(uint8 id) external onlyOwner {
        if (_tiers[id].assets.length == 0) revert TierNotFound();
        _tiers[id].active = true;
        emit TierActivated(id);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full tier struct for off-chain consumption.
     * @dev Reverts if the tier does not exist.
     */
    function getTier(uint8 id) external view returns (
        string memory name_,
        address[] memory assets_,
        uint256[] memory weights_,
        bool active
    ) {
        RiskTier storage tier = _tiers[id];
        if (tier.assets.length == 0) revert TierNotFound();
        return (tier.name, tier.assets, tier.weights, tier.active);
    }

    /**
     * @notice Returns the asset addresses and weights for a tier.
     * @dev Called by {VaultFactory.createVault}. Returns empty arrays for inactive tiers
     *      so the factory's `TierNotActive` check fires correctly.
     * @param id Tier ID.
     * @return assets_  Token addresses in the allocation.
     * @return weights_ Allocation weights in basis points.
     */
    function getTierAssets(uint8 id) external view returns (
        address[] memory assets_,
        uint256[] memory weights_
    ) {
        RiskTier storage tier = _tiers[id];
        if (!tier.active || tier.assets.length == 0) {
            return (new address[](0), new uint256[](0));
        }
        return (tier.assets, tier.weights);
    }

    /**
     * @notice Returns true when `weights` are non-empty and sum to exactly {BPS_DENOMINATOR}.
     * @param weights Array of basis-point weights to validate.
     */
    function validateWeights(uint256[] calldata weights) external pure returns (bool) {
        if (weights.length == 0) return false;
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) sum += weights[i];
        return sum == BPS_DENOMINATOR;
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _validateInputs(address[] calldata assets_, uint256[] calldata weights_) internal pure {
        if (assets_.length == 0) revert EmptyAssets();
        if (assets_.length != weights_.length) revert LengthMismatch();

        uint256 sum;
        for (uint256 i = 0; i < assets_.length; i++) {
            if (assets_[i] == address(0)) revert ZeroAddress();
            sum += weights_[i];
        }
        if (sum != BPS_DENOMINATOR) revert InvalidWeights();
    }
}
