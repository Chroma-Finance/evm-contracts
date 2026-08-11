// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioVault} from "./PortfolioVault.sol";
import {EventNotifier} from "./EventNotifier.sol";
import {RiskTierRegistry} from "../utils/RiskTierRegistry.sol";
import {GuardianModule} from "../modules/GuardianModule.sol";
import {SocialRecoveryModule} from "../modules/SocialRecoveryModule.sol";
import {IChromaSwapRouter} from "../interfaces/ISwapRouter.sol";

/**
 * @title VaultFactory
 * @notice Deploys per-user PortfolioVaults as EIP-1167 minimal proxies and maintains
 *         a registry of all deployed vaults.
 * @dev One vault per user per risk tier enforced via the nested `userVaults` mapping.
 *      Each vault is fully initialized at deployment — no post-deploy setup required.
 *      Owner may upgrade the implementation for new deployments only —
 *      existing vaults are immutable.
 */
contract VaultFactory is Ownable {
    using Clones for address;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Current vault implementation cloned for each new user.
    address public vaultImplementation;

    /// @notice Swap router wired into every new vault at deployment.
    address public swapRouter;

    /// @notice Registry supplying portfolio allocations per risk tier.
    address public riskRegistry;

    /// @notice Address that receives protocol fees from all vaults.
    address public feeRecipient;

    /// @notice Centralized event emitter for all financial events.
    address public eventNotifier;

    /// @notice Shared guardian module for EIP-712 withdrawal approvals.
    GuardianModule public guardianModule;

    /// @notice Shared social recovery module wired into every vault at deployment.
    SocialRecoveryModule public recoveryModule;

    /// @notice User vaults by tier: user => tier => vault.
    mapping(address => mapping(uint8 => address)) public userVaults;

    /// @notice Ordered list of all deployed vaults.
    address[] public allVaults;

    /// @notice Tracks which tier IDs a user has deployed vaults for (for enumeration).
    mapping(address => uint8[]) private userTiers;

    // ─── Events ──────────────────────────────────────────────────────────────

    event ImplementationUpgraded(address indexed oldImpl, address indexed newImpl);
    event FeeRecipientUpdated(address indexed newRecipient);
    event SwapRouterUpdated(address indexed newRouter);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error TierVaultExists();
    error ZeroAddress();
    error TierNotActive();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param swapRouter_    Deployed SwapRouter address (wired into every vault).
     * @param riskRegistry_  Deployed RiskTierRegistry address.
     * @param feeRecipient_  Initial fee recipient (typically the FeeManager).
     */
    constructor(
        address swapRouter_,
        address riskRegistry_,
        address feeRecipient_
    ) Ownable(msg.sender) {
        if (riskRegistry_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        swapRouter   = swapRouter_;
        riskRegistry = riskRegistry_;
        feeRecipient = feeRecipient_;

        vaultImplementation = address(new PortfolioVault());

        EventNotifier notifier = new EventNotifier(address(this));
        eventNotifier = address(notifier);
        notifier.authorize(address(this));

        guardianModule = new GuardianModule();
        recoveryModule = new SocialRecoveryModule();
    }

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Deploys a new PortfolioVault for the caller at the given risk tier.
     * @dev Each user may have at most one vault per tier. Reverts if one already exists.
     *      The vault is fully initialized with immutable references to all shared modules.
     * @param riskTier_   Risk tier index (0=Low, 1=Medium, 2=High).
     * @param enableBoost Whether the YieldOptimizer boost module is enabled (TODO: wire up).
     * @return vault      Address of the newly deployed vault.
     */
    function createVault(uint8 riskTier_, bool enableBoost) external returns (address vault) {
        if (userVaults[msg.sender][riskTier_] != address(0)) revert TierVaultExists();

        (address[] memory tokens, uint256[] memory weights, address[] memory feeds) =
            RiskTierRegistry(riskRegistry).getTier(riskTier_);

        vault = vaultImplementation.clone();

        userVaults[msg.sender][riskTier_] = vault;
        allVaults.push(vault);
        userTiers[msg.sender].push(riskTier_);

        PortfolioVault(vault).initialize(
            msg.sender,
            riskTier_,
            feeRecipient,
            eventNotifier,
            address(guardianModule),
            address(recoveryModule),
            swapRouter,
            tokens,
            weights,
            feeds
        );

        EventNotifier(eventNotifier).authorize(vault);

        // Authorize vault in SwapRouter so it can call batch swap functions.
        if (swapRouter != address(0)) {
            IChromaSwapRouter(swapRouter).authorizeVault(vault);
        }

        // TODO: If enableBoost, register vault with YieldOptimizer.
        (enableBoost);

        EventNotifier(eventNotifier).emitVaultCreated(msg.sender, vault, riskTier_);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Replaces the implementation used for future vault deployments.
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

    /// @notice Updates the swap router applied to newly created vaults.
    function setSwapRouter(address newRouter) external onlyOwner {
        swapRouter = newRouter;
        emit SwapRouterUpdated(newRouter);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    function getUserVault(address user, uint8 tier) external view returns (address) {
        return userVaults[user][tier];
    }

    function getUserVaults(address user)
        external view
        returns (address[] memory vaults, uint8[] memory tiers)
    {
        tiers  = userTiers[user];
        vaults = new address[](tiers.length);
        for (uint256 i = 0; i < tiers.length; i++) {
            vaults[i] = userVaults[user][tiers[i]];
        }
    }

    function hasVault(address user, uint8 tier) external view returns (bool) {
        return userVaults[user][tier] != address(0);
    }

    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function getGuardianModule() external view returns (address) {
        return address(guardianModule);
    }

    function getRecoveryModule() external view returns (address) {
        return address(recoveryModule);
    }

    function getAllVaults(uint256 offset, uint256 limit)
        external view
        returns (address[] memory vaults)
    {
        uint256 end    = offset + limit;
        if (end > allVaults.length) end = allVaults.length;
        uint256 length = end > offset ? end - offset : 0;
        vaults = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            vaults[i] = allVaults[offset + i];
        }
    }
}
