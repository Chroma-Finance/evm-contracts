// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITierYieldRouter} from "../interfaces/ITierYieldRouter.sol";
import {ISingleAssetYieldStrategy} from "../interfaces/ISingleAssetYieldStrategy.sol";

/**
 * @title TierYieldRouter
 * @notice Per-tier Boost routing gateway: an admin-configured asset -> strategy lookup plus
 *         pure forwarding. Holds no share ledger of its own — {SingleAssetYieldStrategy}
 *         subclasses track vault shares directly, keyed by the vault address this router
 *         passes through.
 *
 *         One instance is deployed per tier, referenced as that tier's PortfolioVault's
 *         `yieldOptimizer` address. A single strategy instance (e.g. "WETH into Aave V3") can
 *         be wired into multiple tiers' routers simultaneously — it is not owned by any one
 *         tier or router.
 *
 *         Assets without a configured strategy are simply left uncovered (`strategyOf`
 *         returns address(0)); PortfolioVault leaves those tokens in its own custody instead
 *         of routing them here.
 */
contract TierYieldRouter is ITierYieldRouter, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice VaultFactory permitted to register vaults for this tier.
    address public immutable factory;

    /// @notice Configured strategy per asset. address(0) = uncovered (asset stays in vault).
    mapping(address => address) public strategies;

    /// @notice Vaults authorized to deposit/withdraw through this router.
    mapping(address => bool) public authorizedVaults;

    // ─── Events ──────────────────────────────────────────────────────────────

    event StrategySet(address indexed asset, address indexed strategy);
    event VaultRegistered(address indexed vault);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error StrategyNotConfigured();
    error ZeroAddress();

    // ─── Modifier ────────────────────────────────────────────────────────────

    modifier onlyAuthorizedVault() {
        if (!authorizedVaults[msg.sender]) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param factory_ VaultFactory permitted to register vaults for this tier.
    constructor(address factory_) Ownable(msg.sender) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /**
     * @notice Wires (or unwires) the strategy this router forwards `asset` deposits to.
     * @dev `strategy` may be address(0) — this is the explicit unwire/disable action for
     *      `asset`, not an error.
     * @param asset    Portfolio asset to configure.
     * @param strategy Strategy to route `asset` through, or address(0) to disable.
     */
    function setStrategy(address asset, address strategy) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        strategies[asset] = strategy;
        emit StrategySet(asset, strategy);
    }

    // ─── External ────────────────────────────────────────────────────────────

    /// @notice Returns the strategy configured for `asset`, or address(0) if uncovered.
    function strategyOf(address asset) external view returns (address) {
        return strategies[asset];
    }

    /// @notice Authorizes a vault to call {deposit} and {withdrawAll}.
    /// @dev Callable only by the VaultFactory, matching SwapRouter.authorizeVault() and
    ///      EventNotifier.authorize()'s existing registration pattern.
    function registerVault(address vault) external {
        if (msg.sender != factory) revert Unauthorized();
        authorizedVaults[vault] = true;
        emit VaultRegistered(vault);
    }

    /**
     * @notice Deposits `amount` of `asset` on behalf of the calling vault into its configured
     *         strategy.
     * @dev Caller must approve this contract for `amount` first. Reverts if `asset` has no
     *      strategy configured — the router must not silently succeed or swallow funds if
     *      called incorrectly.
     * @param asset  Portfolio asset being deposited.
     * @param amount Amount of `asset` to deposit.
     */
    function deposit(address asset, uint256 amount) external onlyAuthorizedVault {
        address strategy = strategies[asset];
        if (strategy == address(0)) revert StrategyNotConfigured();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(strategy, amount);
        ISingleAssetYieldStrategy(strategy).deposit(msg.sender, amount);
    }

    /**
     * @notice Withdraws the calling vault's entire strategy position in `asset` and returns
     *         the underlying amount transferred back to the caller.
     * @param asset Portfolio asset being withdrawn.
     * @return amount Underlying asset amount transferred to the caller.
     */
    function withdrawAll(address asset) external onlyAuthorizedVault returns (uint256 amount) {
        address strategy = strategies[asset];
        if (strategy == address(0)) revert StrategyNotConfigured();

        amount = ISingleAssetYieldStrategy(strategy).withdrawAll(msg.sender);
        if (amount > 0) IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Returns `vault`'s proportional value in `asset`.
     * @dev Returns 0 (does not revert) for an uncovered asset — that just means the asset was
     *      never moved out of the vault in the first place; PortfolioVault reads its own
     *      balance for that case instead.
     */
    function valueOf(address vault, address asset) external view returns (uint256) {
        address strategy = strategies[asset];
        if (strategy == address(0)) return 0;
        return ISingleAssetYieldStrategy(strategy).valueOf(vault);
    }
}
