// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IYieldOptimizer} from "../interfaces/IYieldOptimizer.sol";
import {FeeManager} from "../utils/FeeManager.sol";

/**
 * @title YieldOptimizerCore
 * @notice Abstract Boost module: deploys authorized vaults' idle portfolio assets into an
 *         external yield strategy and tracks each vault's claim via an internal share ledger.
 *
 *         Design principles:
 *         - Strategy-agnostic core: token deployment/redemption logic lives in the
 *           strategy-specific virtual functions implemented by subclasses.
 *         - Share accounting mirrors {PortfolioVault}'s USD share math exactly — the same
 *           mulDiv virtual +1 offset pattern prevents inflation attacks and division-by-zero
 *           at initialization (see PortfolioVault.deposit() / _convertToAssets()).
 *         - Boost fee (default 15%) is skimmed from harvested yield only, forwarded to
 *           {FeeManager} via its existing pull-based collectFees().
 */
abstract contract YieldOptimizerCore is IYieldOptimizer, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Factory permitted to register vaults.
    address public immutable factory;

    /// @notice FeeManager that receives the boost fee share of harvested yield.
    address public immutable feeManager;

    /// @notice Ordered list of underlying asset tokens deployed by the strategy.
    address[] public assetTokens;

    /// @notice Vaults authorized to deposit/withdraw Boost shares.
    mapping(address => bool) public authorizedVaults;

    /// @notice Boost shares held per vault.
    mapping(address => uint256) public sharesOf;

    /// @notice Total Boost shares outstanding.
    uint256 public totalShares;

    /// @notice Pauses new deposits. Does not block withdrawals.
    bool public paused;

    /// @notice Fee charged on generated yield in basis points (default 15%, matches original stub).
    uint256 public boostFeeBps = 1_500;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant MAX_BOOST_FEE_BPS = 3_000; // hard cap 30%, sanity bound

    // ─── Events ──────────────────────────────────────────────────────────────

    event VaultRegistered(address indexed vault);
    event Deposited(address indexed vault, uint256 shares, uint256[] amounts);
    event Withdrawn(address indexed vault, uint256 shares, uint256[] amounts);
    event Harvested(address indexed token, uint256 feeAmount);
    event EmergencyExit();
    event BoostFeeUpdated(uint256 newBps);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error Unauthorized();
    error Paused();
    error ZeroShares();
    error InsufficientShares();
    error BelowMinimum();
    error ArrayLengthMismatch();
    error ZeroAddress();
    error ExceedsMax();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyAuthorizedVault() {
        if (!authorizedVaults[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param factory_    VaultFactory permitted to register vaults.
     * @param feeManager_ FeeManager that receives the boost fee.
     * @param assets_     Ordered underlying asset tokens deployed by this strategy.
     */
    constructor(address factory_, address feeManager_, address[] memory assets_) Ownable(msg.sender) {
        if (factory_ == address(0) || feeManager_ == address(0)) revert ZeroAddress();
        factory     = factory_;
        feeManager  = feeManager_;
        assetTokens = assets_;
    }

    // ─── External ────────────────────────────────────────────────────────────

    /// @notice Authorizes a vault to deposit/withdraw Boost shares.
    /// @dev Callable only by the VaultFactory.
    function registerVault(address vault) external onlyFactory {
        authorizedVaults[vault] = true;
        emit VaultRegistered(vault);
    }

    /**
     * @notice Deposits portfolio token amounts and mints Boost shares to the caller.
     * @dev Caller must be an authorized vault and must approve this contract for each amount
     *      first. Share math mirrors PortfolioVault.deposit(): mulDiv with virtual +1 offsets
     *      on both totalShares and units-deployed-before-this-call, preventing inflation
     *      attacks and division-by-zero on the very first deposit.
     * @param amounts Amounts of each underlying asset (order matches {assetTokens}).
     * @return sharesMinted Boost shares minted to the caller.
     */
    function deposit(uint256[] calldata amounts)
        external
        nonReentrant
        onlyAuthorizedVault
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        uint256 n = assetTokens.length;
        if (amounts.length != n) revert ArrayLengthMismatch();

        uint256 unitsBefore = _totalUnits();

        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                IERC20(assetTokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
        }

        uint256 unitsAdded = _deploy(amounts);

        sharesMinted = unitsAdded.mulDiv(totalShares + 1, unitsBefore + 1, Math.Rounding.Floor);
        if (sharesMinted == 0) revert BelowMinimum();

        sharesOf[msg.sender] += sharesMinted;
        totalShares          += sharesMinted;

        emit Deposited(msg.sender, sharesMinted, amounts);
    }

    /**
     * @notice Burns `shares` and returns the underlying token amounts to the caller.
     * @dev Share accounting (sharesOf, totalShares) is updated before the external strategy
     *      redemption call so a reentrant call cannot double-spend the caller's shares.
     * @param shares Boost shares to redeem.
     * @return amountsOut Underlying token amounts returned (order matches {assetTokens}).
     */
    function withdraw(uint256 shares)
        external
        nonReentrant
        onlyAuthorizedVault
        returns (uint256[] memory amountsOut)
    {
        if (shares == 0) revert ZeroShares();
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();

        uint256 priorTotalShares = totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares          -= shares;

        amountsOut = _redeem(shares, priorTotalShares);

        for (uint256 i = 0; i < amountsOut.length; i++) {
            if (amountsOut[i] > 0) {
                IERC20(assetTokens[i]).safeTransfer(msg.sender, amountsOut[i]);
            }
        }

        emit Withdrawn(msg.sender, shares, amountsOut);
    }

    /// @notice Permissionlessly claims yield, skims the boost fee, and re-deploys the remainder.
    function harvest() external nonReentrant {
        _harvest();
    }

    /// @notice Pulls 100% of deployed assets back into this contract and pauses new deposits.
    function emergencyWithdrawAll() external onlyOwner nonReentrant {
        paused = true;
        _emergencyExit();
        emit EmergencyExit();
    }

    /// @notice Updates the boost fee charged on harvested yield.
    /// @dev Hard-capped at {MAX_BOOST_FEE_BPS} (30%) as a sanity bound.
    function setBoostFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_BOOST_FEE_BPS) revert ExceedsMax();
        boostFeeBps = newBps;
        emit BoostFeeUpdated(newBps);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /// @notice Returns the total deployed amount of each underlying asset held by the strategy.
    function totalAssets() external view returns (uint256[] memory) {
        return _totalAssets();
    }

    /// @notice Returns `vault`'s proportional share of each underlying asset.
    function valueOf(address vault) external view returns (uint256[] memory result) {
        uint256[] memory total = _totalAssets();
        uint256 vaultShares    = sharesOf[vault];
        uint256 supply         = totalShares;

        result = new uint256[](total.length);
        if (supply == 0) return result;

        for (uint256 i = 0; i < total.length; i++) {
            result[i] = (total[i] * vaultShares) / supply;
        }
    }

    /// @notice Returns the ordered list of underlying asset tokens.
    function assets() external view returns (address[] memory) {
        return assetTokens;
    }

    // ─── Internal: boost fee ─────────────────────────────────────────────────

    /**
     * @notice Skims {boostFeeBps} of `grossYield` and forwards it to {FeeManager}.
     * @dev Call from within each strategy's _harvest() implementation. Uses FeeManager's
     *      existing pull-based collectFees(token, amount) exactly as designed — FeeManager
     *      itself needs no changes.
     * @param token      Yield token being harvested.
     * @param grossYield Total yield collected before the boost fee.
     * @return netYield  Yield remaining after the boost fee.
     */
    function _collectBoostFee(address token, uint256 grossYield) internal returns (uint256 netYield) {
        uint256 fee = (grossYield * boostFeeBps) / BPS_DENOMINATOR;
        if (fee > 0) {
            IERC20(token).forceApprove(feeManager, fee);
            FeeManager(feeManager).collectFees(token, fee);
            emit Harvested(token, fee);
        }
        netYield = grossYield - fee;
    }

    // ─── Strategy hooks ──────────────────────────────────────────────────────

    /// @dev Deploys `amounts` of each underlying asset into the strategy. Returns the scalar
    ///      unit increase used for share-minting math (e.g. LP liquidity delta).
    function _deploy(uint256[] calldata amounts) internal virtual returns (uint256 unitsAdded);

    /// @dev Redeems `shares` (out of `priorTotalShares`) from the strategy, returning the
    ///      underlying token amounts already rebalanced to the ratio the vault expects.
    function _redeem(uint256 shares, uint256 priorTotalShares) internal virtual returns (uint256[] memory);

    /// @dev Scalar total deployed units used for share-minting math only.
    function _totalUnits() internal view virtual returns (uint256);

    /// @dev Per-token total assets represented by the strategy, for valueOf() / totalAssets().
    function _totalAssets() internal view virtual returns (uint256[] memory);

    /// @dev Claims yield, skims the boost fee via {_collectBoostFee}, and re-deploys the rest.
    function _harvest() internal virtual;

    /// @dev Pulls 100% of deployed assets back into this contract as raw tokens.
    function _emergencyExit() internal virtual;
}
