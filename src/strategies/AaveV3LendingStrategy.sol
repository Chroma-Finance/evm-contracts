// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SingleAssetYieldStrategy} from "../modules/SingleAssetYieldStrategy.sol";

/**
 * @notice Minimal interface to the Aave V3 Pool.
 * @dev Deliberately does NOT import Aave's full `@aave/core-v3` interfaces — only the
 *      functions and struct fields {AaveV3LendingStrategy} actually uses are declared here.
 *      `ReserveData`'s field order/types match the real deployed Pool exactly, verified
 *      on-chain against Arbitrum One (`getReserveData` decodes correctly against the live
 *      contract), so it is safe to cast the on-chain address to this interface.
 */
interface IAavePool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40  lastUpdateTimestamp;
        uint16  id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveData(address asset) external view returns (ReserveData memory);
}

/**
 * @title AaveV3LendingStrategy
 * @notice Single-asset Boost strategy that deposits into Aave V3, on behalf of every vault
 *         (across every tier's {TierYieldRouter}) routed into it for this asset.
 *
 *         Aave's aTokens rebase 1:1 with underlying + accrued interest, so the aToken balance
 *         held by this contract already reflects the current total value — base lending yield
 *         needs no separate harvest step to be captured; see {SingleAssetYieldStrategy}'s TODO
 *         for the deliberately-deferred fee-skim decision.
 */
contract AaveV3LendingStrategy is SingleAssetYieldStrategy {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 Pool this strategy supplies/withdraws through.
    IAavePool public immutable aavePool;

    /// @notice Aave V3 interest-bearing token for {underlyingAsset}, derived on-chain from
    ///         `aavePool`'s own reserve registry rather than accepted as a constructor argument.
    IERC20 public immutable aToken;

    /**
     * @param feeManager_ FeeManager that will receive the boost fee once implemented.
     * @param asset_      The single underlying asset this strategy deploys into Aave V3.
     * @param aavePool_   Aave V3 Pool proxy address.
     */
    constructor(address feeManager_, address asset_, address aavePool_)
        SingleAssetYieldStrategy(feeManager_, asset_)
    {
        if (aavePool_ == address(0)) revert ZeroAddress();
        aavePool = IAavePool(aavePool_);

        // Derived on-chain rather than passed separately — self-verifies against Aave's own
        // registry instead of trusting an address that could be stale or mismatched.
        aToken = IERC20(aavePool.getReserveData(asset_).aTokenAddress);
        if (address(aToken) == address(0)) revert ZeroAddress();
    }

    // ─── Strategy hooks ──────────────────────────────────────────────────────

    /// @dev Supplies `amount` to Aave V3 and measures the actual aToken delta credited —
    ///      aTokens are rebasing, so this is the correct, defensive way to capture what was
    ///      credited rather than assuming a 1:1 mint.
    function _deploy(uint256 amount) internal override returns (uint256 unitsAdded) {
        uint256 aTokenBalanceBefore = aToken.balanceOf(address(this));

        IERC20(underlyingAsset).forceApprove(address(aavePool), amount);
        aavePool.supply(underlyingAsset, amount, address(this), 0);

        unitsAdded = aToken.balanceOf(address(this)) - aTokenBalanceBefore;
    }

    /// @dev Withdraws the proportional slice of the current aToken balance. Uses Aave's own
    ///      returned amount (not the requested amount) since it may differ negligibly due to
    ///      rounding.
    function _redeem(uint256 shares, uint256 priorTotalShares) internal override returns (uint256 amountOut) {
        uint256 aTokenBalance     = aToken.balanceOf(address(this));
        uint256 amountToWithdraw  = (aTokenBalance * shares) / priorTotalShares;
        if (amountToWithdraw == 0) return 0;

        amountOut = aavePool.withdraw(underlyingAsset, amountToWithdraw, address(this));
    }

    /// @dev aTokens rebase 1:1 with underlying + accrued interest — this single balance read
    ///      IS the current total value in underlying-asset terms.
    function _totalUnits() internal view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @dev Withdraws the entire aToken balance back to raw underlying tokens.
    function _emergencyExit() internal override {
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if (aTokenBalance > 0) {
            // Aave V3's withdraw() treats type(uint256).max as "withdraw the entire aToken
            // balance" — the documented convention for the deployed Pool version.
            aavePool.withdraw(underlyingAsset, type(uint256).max, address(this));
        }
    }
}
