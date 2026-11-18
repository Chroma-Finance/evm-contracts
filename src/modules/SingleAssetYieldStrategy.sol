// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISingleAssetYieldStrategy} from "../interfaces/ISingleAssetYieldStrategy.sol";

// TODO: No harvest / fee-skim mechanism yet. FeeManager is 0% at launch project-wide, and
//       fee capture for continuously-accruing yield (share dilution, matching PortfolioVault's
//       own management fee pattern) is a deliberately separate, not-yet-confirmed decision.

/**
 * @title SingleAssetYieldStrategy
 * @notice Abstract base for single-asset lending-style Boost strategies (e.g. Aave V3).
 *
 *         Parallel to {YieldOptimizerCore}, not an extension of it: that base assumes one
 *         shared multi-asset position accessed directly by vaults. This family instead
 *         backs a single underlying asset, is accessed only through an authorized
 *         {ITierYieldRouter} (never a vault directly), and tracks each depositor by their
 *         explicit `vault` address rather than msg.sender — a single strategy instance can be
 *         wired into multiple tiers' routers simultaneously.
 *
 *         Share accounting mirrors {YieldOptimizerCore}'s USD-free unit-based math exactly:
 *         the same mulDiv virtual +1 offset pattern prevents inflation attacks and
 *         division-by-zero at initialization.
 */
abstract contract SingleAssetYieldStrategy is ISingleAssetYieldStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice The single underlying asset this strategy deploys.
    address public immutable underlyingAsset;

    /// @notice FeeManager that will receive a boost fee once fee-skimming is implemented.
    address public immutable feeManager;

    /// @notice Routers authorized to deposit/withdraw on behalf of vaults.
    mapping(address => bool) public authorizedRouters;

    /// @notice Strategy shares held per original vault address.
    mapping(address => uint256) public sharesOf;

    /// @notice Total strategy shares outstanding.
    uint256 public totalShares;

    /// @notice Pauses new deposits. Does not block withdrawals.
    bool public paused;

    // ─── Events ──────────────────────────────────────────────────────────────

    event RouterRegistered(address indexed router);
    event Deposited(address indexed vault, uint256 amount, uint256 shares);
    event Withdrawn(address indexed vault, uint256 amount, uint256 shares);
    event EmergencyExit();

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error Paused();
    error ZeroAmount();
    error ZeroShares();
    error ZeroAddress();

    // ─── Modifier ────────────────────────────────────────────────────────────

    modifier onlyAuthorizedRouter() {
        if (!authorizedRouters[msg.sender]) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param feeManager_ FeeManager that will receive the boost fee once implemented.
     * @param asset_      The single underlying asset this strategy deploys.
     */
    constructor(address feeManager_, address asset_) Ownable(msg.sender) {
        if (feeManager_ == address(0) || asset_ == address(0)) revert ZeroAddress();
        feeManager      = feeManager_;
        underlyingAsset = asset_;
    }

    // ─── External ────────────────────────────────────────────────────────────

    /// @notice Returns the single underlying asset this strategy deploys.
    function asset() external view returns (address) {
        return underlyingAsset;
    }

    /// @notice Authorizes a router to deposit/withdraw on behalf of vaults.
    /// @dev Owner-only. A single strategy instance may be wired into multiple tiers' routers.
    function registerRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        authorizedRouters[router] = true;
        emit RouterRegistered(router);
    }

    /**
     * @notice Deposits `amount` of the underlying asset for `vault` and mints strategy shares.
     * @dev Caller must be an authorized router that has already pulled `amount` from `vault`
     *      and approved this contract for it. Share math mirrors YieldOptimizerCore.deposit():
     *      mulDiv with virtual +1 offsets on both totalShares and units-deployed-before-this-call.
     * @param vault  Original vault address the shares are credited to.
     * @param amount Amount of the underlying asset to deposit.
     * @return shares Strategy shares minted to `vault`.
     */
    function deposit(address vault, uint256 amount)
        external
        onlyAuthorizedRouter
        returns (uint256 shares)
    {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();

        IERC20(underlyingAsset).safeTransferFrom(msg.sender, address(this), amount);

        uint256 priorTotalUnits = _totalUnits();
        uint256 unitsAdded      = _deploy(amount);

        shares = unitsAdded.mulDiv(totalShares + 1, priorTotalUnits + 1, Math.Rounding.Floor);

        sharesOf[vault] += shares;
        totalShares     += shares;

        emit Deposited(vault, amount, shares);
    }

    /**
     * @notice Redeems 100% of `vault`'s strategy shares and returns the underlying amount.
     * @dev Caller must be an authorized router; the underlying amount is transferred to the
     *      calling router, which relays it onward to `vault`.
     * @param vault Original vault address whose full position is being redeemed.
     * @return amount Underlying asset amount transferred to the caller.
     */
    function withdrawAll(address vault) external onlyAuthorizedRouter returns (uint256 amount) {
        uint256 shares = sharesOf[vault];
        if (shares == 0) revert ZeroShares();

        uint256 priorTotalShares = totalShares;
        sharesOf[vault] = 0;
        totalShares     -= shares;

        amount = _redeem(shares, priorTotalShares);

        if (amount > 0) IERC20(underlyingAsset).safeTransfer(msg.sender, amount);

        emit Withdrawn(vault, amount, shares);
    }

    /// @notice Returns `vault`'s proportional value of the underlying asset.
    function valueOf(address vault) external view returns (uint256) {
        uint256 shares = sharesOf[vault];
        if (shares == 0 || totalShares == 0) return 0;
        return (_totalUnits() * shares) / totalShares;
    }

    /// @notice Pulls 100% of deployed assets back into this contract and pauses new deposits.
    function emergencyWithdrawAll() external onlyOwner {
        paused = true;
        _emergencyExit();
        emit EmergencyExit();
    }

    // ─── Strategy hooks ──────────────────────────────────────────────────────

    /// @dev Deploys `amount` of the underlying asset into the strategy. Returns the scalar
    ///      unit increase used for share-minting math (e.g. aToken balance delta).
    function _deploy(uint256 amount) internal virtual returns (uint256 unitsAdded);

    /// @dev Redeems `shares` (out of `priorTotalShares`) from the strategy, returning the
    ///      underlying asset amount.
    function _redeem(uint256 shares, uint256 priorTotalShares) internal virtual returns (uint256 amountOut);

    /// @dev Scalar total deployed units used for share-minting math and {valueOf}.
    function _totalUnits() internal view virtual returns (uint256);

    /// @dev Pulls 100% of deployed assets back into this contract as raw underlying tokens.
    function _emergencyExit() internal virtual;
}
