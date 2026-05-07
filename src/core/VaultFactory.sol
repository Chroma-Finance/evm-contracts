// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioVault} from "./PortfolioVault.sol";
import {EventNotifier} from "./EventNotifier.sol";
import {RiskTierRegistry} from "../utils/RiskTierRegistry.sol";

/**
 * @title VaultFactory
 * @notice Deploys per-user PortfolioVaults as EIP-1167 minimal proxies and maintains
 *         a registry of all deployed vaults.
 * @dev One vault per user per risk tier enforced via the nested `userVaults` mapping.
 *      Owner may upgrade the implementation for new deployments only —
 *      existing vaults are immutable.
 */
contract VaultFactory is Ownable {
    using Clones for address;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Current vault implementation cloned for each new user.
    address public vaultImplementation;

    /// @notice Denomination asset used by all vaults (e.g., USDC on Arbitrum).
    address public denominationAsset;

    /// @notice Registry supplying portfolio allocations per risk tier.
    address public riskRegistry;

    /// @notice Address that receives protocol fees from all vaults.
    address public feeRecipient;

    /// @notice Centralized event emitter for all financial events.
    address public eventNotifier;

    /// @notice User vaults by tier: user => tier => vault.
    mapping(address => mapping(uint8 => address)) public userVaults;

    /// @notice Ordered list of all deployed vaults.
    address[] public allVaults;

    /// @notice Tracks which tier IDs a user has deployed vaults for (for enumeration).
    mapping(address => uint8[]) private userTiers;

    // ─── Events ──────────────────────────────────────────────────────────────

    // VaultCreated is emitted by EventNotifier (centralized financial event tracking).
    event ImplementationUpgraded(address indexed oldImpl, address indexed newImpl);
    event FeeRecipientUpdated(address indexed newRecipient);
    event DenominationAssetUpdated(address indexed newAsset);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error TierVaultExists();
    error ZeroAddress();
    error TierNotActive();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param denominationAsset_ Denomination token for deposit/withdraw (e.g., USDC).
     * @param riskRegistry_      Deployed RiskTierRegistry address.
     * @param feeRecipient_      Initial fee recipient (typically the FeeManager).
     */
    constructor(
        address denominationAsset_,
        address riskRegistry_,
        address feeRecipient_
    ) Ownable(msg.sender) {
        if (denominationAsset_ == address(0) || riskRegistry_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        denominationAsset = denominationAsset_;
        riskRegistry = riskRegistry_;
        feeRecipient = feeRecipient_;
        vaultImplementation = address(new PortfolioVault());

        EventNotifier notifier = new EventNotifier(address(this));
        eventNotifier = address(notifier);
        // Factory must be authorized to call emitVaultCreated.
        notifier.authorize(address(this));
    }

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Deploys a new PortfolioVault for the caller for the given risk tier.
     * @dev Each user may have at most one vault per tier. Reverts if one already exists.
     * @param riskTier_   Risk tier index (0=Low, 1=Medium, 2=High).
     * @param enableBoost Whether the YieldOptimizer boost module is enabled (TODO: wire up).
     * @return vault      Address of the newly deployed vault.
     */
    function createVault(uint8 riskTier_, bool enableBoost) external returns (address vault) {
        if (userVaults[msg.sender][riskTier_] != address(0)) revert TierVaultExists();

        // Retrieve allocation from the registry (reverts if tier inactive or not found).
        (address[] memory tokens, uint256[] memory weights,) =
            RiskTierRegistry(riskRegistry).getTier(riskTier_);

        vault = vaultImplementation.clone();

        PortfolioVault(vault).initialize(
            msg.sender,
            riskTier_,
            denominationAsset,
            feeRecipient,
            eventNotifier,
            tokens,
            weights
        );

        // Authorize vault to emit financial events through EventNotifier.
        EventNotifier(eventNotifier).authorize(vault);

        userVaults[msg.sender][riskTier_] = vault;
        allVaults.push(vault);
        userTiers[msg.sender].push(riskTier_);

        // TODO: If enableBoost, register vault with YieldOptimizer.
        (enableBoost); // suppress unused-param warning until YieldOptimizer is wired

        EventNotifier(eventNotifier).emitVaultCreated(msg.sender, vault, riskTier_);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /**
     * @notice Replaces the implementation used for future vault deployments.
     * @dev Does not affect existing vaults.
     */
    function upgradeImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert ZeroAddress();
        emit ImplementationUpgraded(vaultImplementation, newImpl);
        vaultImplementation = newImpl;
    }

    /// @notice Updates the fee recipient applied to newly created vaults.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice Updates the denomination asset for newly created vaults.
    function setDenominationAsset(address newAsset) external onlyOwner {
        if (newAsset == address(0)) revert ZeroAddress();
        denominationAsset = newAsset;
        emit DenominationAssetUpdated(newAsset);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /**
     * @notice Returns the vault address for a given user and tier (address(0) if none).
     */
    function getUserVault(address user, uint8 tier) external view returns (address vault) {
        return userVaults[user][tier];
    }

    /**
     * @notice Returns all vault addresses and their corresponding tier IDs for a user.
     */
    function getUserVaults(address user)
        external
        view
        returns (address[] memory vaults, uint8[] memory tiers)
    {
        tiers = userTiers[user];
        vaults = new address[](tiers.length);
        for (uint256 i = 0; i < tiers.length; i++) {
            vaults[i] = userVaults[user][tiers[i]];
        }
    }

    /// @notice Returns true if the user has a vault for the specified tier.
    function hasVault(address user, uint8 tier) external view returns (bool) {
        return userVaults[user][tier] != address(0);
    }

    /// @notice Total number of deployed vaults.
    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /**
     * @notice Returns a paginated slice of all deployed vault addresses.
     * @param offset Starting index (inclusive).
     * @param limit  Maximum number of addresses to return.
     */
    function getAllVaults(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory vaults)
    {
        uint256 end = offset + limit;
        if (end > allVaults.length) end = allVaults.length;
        uint256 length = end > offset ? end - offset : 0;
        vaults = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            vaults[i] = allVaults[offset + i];
        }
    }
}
