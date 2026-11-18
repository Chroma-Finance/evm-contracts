// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3LendingStrategy} from "../../src/strategies/AaveV3LendingStrategy.sol";
import {SingleAssetYieldStrategy} from "../../src/modules/SingleAssetYieldStrategy.sol";
import {FeeManager} from "../../src/utils/FeeManager.sol";

/**
 * @notice Fork tests for AaveV3LendingStrategy against the real, live Aave V3 Pool on Arbitrum.
 *
 *         Run with:
 *           source .env && forge test --match-path "test/fork/AaveV3LendingStrategyFork.t.sol" \
 *             --fork-url $ARBITRUM_RPC_URL -vvvv
 *
 *         The test contract itself acts as both the "factory" (irrelevant here) and the
 *         "router" caller, so deposit()/withdrawAll() can be exercised directly without
 *         standing up a full TierYieldRouter.
 */
contract AaveV3LendingStrategyForkTest is Test {
    address internal usdc;
    address internal aavePoolAddr;

    address internal treasury = makeAddr("treasury");
    address internal devFund  = makeAddr("devFund");
    address internal vault1   = makeAddr("vault1");
    address internal vault2   = makeAddr("vault2");

    FeeManager            internal feeManager;
    AaveV3LendingStrategy internal strategy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));

        usdc         = vm.envAddress("USDC");
        aavePoolAddr = vm.envAddress("AAVE_POOL_ARBITRUM");

        feeManager = new FeeManager(treasury, devFund);
        strategy   = new AaveV3LendingStrategy(address(feeManager), usdc, aavePoolAddr);
        strategy.registerRouter(address(this));

        console2.log("Aave Pool :", aavePoolAddr);
        console2.log("USDC      :", usdc);
        console2.log("aUSDC     :", address(strategy.aToken()));
    }

    function _dealAndApprove(uint256 amount) internal {
        deal(usdc, address(this), amount);
        IERC20(usdc).approve(address(strategy), amount);
    }

    // ─── deposit ─────────────────────────────────────────────────────────────

    function test_deposit_suppliesToRealAaveV3Pool() public {
        _dealAndApprove(10_000e6);

        uint256 shares = strategy.deposit(vault1, 10_000e6);

        assertGt(shares, 0, "no shares minted");
        assertEq(strategy.sharesOf(vault1), shares);
        assertApproxEqAbs(
            IERC20(address(strategy.aToken())).balanceOf(address(strategy)),
            10_000e6,
            1,
            "aToken balance does not match supplied amount"
        );

        console2.log("Shares minted   :", shares);
        console2.log("aToken balance  :", IERC20(address(strategy.aToken())).balanceOf(address(strategy)));
    }

    // ─── withdrawAll ─────────────────────────────────────────────────────────

    function test_withdrawAll_realWithdrawReturnsFullPrincipal() public {
        _dealAndApprove(10_000e6);
        strategy.deposit(vault1, 10_000e6);

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 amount = strategy.withdrawAll(vault1);
        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));

        assertApproxEqAbs(amount, 10_000e6, 1, "withdrawn amount deviates from deposited principal");
        assertEq(usdcAfter - usdcBefore, amount);
        assertEq(strategy.sharesOf(vault1), 0);
        assertEq(strategy.totalShares(), 0);

        console2.log("Amount withdrawn:", amount);
    }

    // ─── yield auto-compounds with no harvest call ──────────────────────────

    function test_totalUnits_growsOverTimeWithNoAdditionalDepositOrHarvest() public {
        _dealAndApprove(1_000_000e6); // sizeable deposit so accrued interest is measurable
        strategy.deposit(vault1, 1_000_000e6);

        uint256 unitsBefore = IERC20(address(strategy.aToken())).balanceOf(address(strategy));

        // Warp forward with no further strategy interaction — base Aave V3 lending yield
        // must already be reflected in the rebasing aToken balance with no harvest() call,
        // since none exists in this architecture (see SingleAssetYieldStrategy's TODO).
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + 1);

        uint256 unitsAfter = IERC20(address(strategy.aToken())).balanceOf(address(strategy));

        assertGt(unitsAfter, unitsBefore, "aToken balance did not grow over time with no deposit");

        // valueOf() must reflect the same auto-compounded growth for the single depositing vault.
        uint256 vaultValue = strategy.valueOf(vault1);
        assertEq(vaultValue, unitsAfter, "valueOf does not track grown aToken balance for sole depositor");

        console2.log("aToken units before warp:", unitsBefore);
        console2.log("aToken units after warp :", unitsAfter);
        console2.log("Yield accrued            :", unitsAfter - unitsBefore);
    }

    // ─── emergencyWithdrawAll ────────────────────────────────────────────────

    function test_emergencyWithdrawAll_pullsEverythingBackAndPauses() public {
        _dealAndApprove(10_000e6);
        strategy.deposit(vault1, 10_000e6);

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(strategy));

        strategy.emergencyWithdrawAll();

        assertTrue(strategy.paused(), "strategy not paused");
        assertEq(IERC20(address(strategy.aToken())).balanceOf(address(strategy)), 0, "aToken not fully withdrawn");

        uint256 usdcAfter = IERC20(usdc).balanceOf(address(strategy));
        assertGt(usdcAfter, usdcBefore, "no USDC pulled back into the strategy");
        assertApproxEqAbs(usdcAfter, 10_000e6, 1, "USDC pulled back deviates from deposited principal");

        // Further deposits must revert while paused.
        _dealAndApprove(1_000e6);
        vm.expectRevert(SingleAssetYieldStrategy.Paused.selector);
        strategy.deposit(vault2, 1_000e6);

        console2.log("USDC recovered:", usdcAfter);
    }
}
