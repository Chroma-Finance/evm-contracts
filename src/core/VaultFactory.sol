// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioVault} from "./PortfolioVault.sol";
import {RiskTierRegistry} from "../utils/RiskTierRegistry.sol";

/**
 * @title VaultFactory
 * @notice Deploys per-user PortfolioVaults as EIP-1167 minimal proxies and maintains
 *         a registry of all deployed vaults.
 * @dev One vault per user address enforced via the `userVaults` mapping.
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

    /// @notice user → vault address (one vault per user).
    mapping(address => address) public userVaults;

    /// @notice Ordered list of all deployed vaults.
    address[] public allVaults;

    // ─── Events ──────────────────────────────────────────────────────────────

    event VaultCreated(address indexed user, address indexed vault, uint8 riskTier, bool boostEnabled);
    event ImplementationUpgraded(address indexed oldImpl, address indexed newImpl);
    event FeeRecipientUpdated(address indexed newRecipient);
    event DenominationAssetUpdated(address indexed newAsset);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyHasVault();
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
    }

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Deploys a new PortfolioVault for the caller.
     * @param riskTier_    Risk tier index (0=Low, 1=Medium, 2=High).
     * @param enableBoost  Whether the YieldOptimizer boost module is enabled.
     * @return vault       Address of the newly deployed vault.
     */
    function createVault(uint8 riskTier_, bool enableBoost) external returns (address vault) {
        if (userVaults[msg.sender] != address(0)) revert AlreadyHasVault();

        // Retrieve allocation from the registry.
        RiskTierRegistry registry = RiskTierRegistry(riskRegistry);
        (address[] memory tokens, uint256[] memory weights) = registry.getTierAssets(riskTier_);
        if (tokens.length == 0) revert TierNotActive();

        vault = vaultImplementation.clone();

        PortfolioVault(vault).initialize(
            msg.sender,
            riskTier_,
            denominationAsset,
            feeRecipient,
            tokens,
            weights
        );

        userVaults[msg.sender] = vault;
        allVaults.push(vault);

        // TODO: If enableBoost, register vault with YieldOptimizer.

        emit VaultCreated(msg.sender, vault, riskTier_, enableBoost);
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

    /// @notice Returns the vault address for a given user (address(0) if none).
    function getUserVault(address user) external view returns (address) {
        return userVaults[user];
    }

    /// @notice Total number of deployed vaults.
    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Returns the full list of deployed vault addresses.
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
}
