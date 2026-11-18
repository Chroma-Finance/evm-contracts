// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter as IUniswapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {UniswapV3LPStrategy} from "../../src/strategies/UniswapV3LPStrategy.sol";
import {YieldOptimizerCore} from "../../src/modules/YieldOptimizerCore.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {SwapRouter} from "../../src/utils/SwapRouter.sol";
import {FeeManager} from "../../src/utils/FeeManager.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @notice Fork tests for UniswapV3LPStrategy against a live Arbitrum WBTC/WETH pool.
 *
 *         Run with:
 *           source .env && forge test --match-path "test/fork/UniswapV3LPStrategyFork.t.sol" \
 *             --fork-url $ARBITRUM_RPC_URL -vvvv
 *
 *         The test contract itself acts as both the "factory" (registers itself as an
 *         authorized vault) and the sole "vault" caller, so deposit()/withdraw()/harvest()
 *         can be exercised directly without standing up a full PortfolioVault.
 */
contract UniswapV3LPStrategyForkTest is Test {
    address internal constant UNISWAP_V3_FACTORY   = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant POSITION_MANAGER     = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24  internal constant POOL_FEE             = 3000;

    address internal wbtc;
    address internal weth;
    address internal uniswapRouterAddr;
    address internal pool;

    address internal treasury = makeAddr("treasury");
    address internal devFund  = makeAddr("devFund");

    SwapRouter          internal chromaRouter;
    FeeManager          internal feeManager;
    UniswapV3LPStrategy internal strategy;

    int24 internal tickLower;
    int24 internal tickUpper;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));

        wbtc              = vm.envAddress("WBTC");
        weth              = vm.envAddress("WETH");
        uniswapRouterAddr = vm.envAddress("UNISWAP_V3_ROUTER");
        address btcUsdFeed = vm.envAddress("BTC_USD_FEED");
        address ethUsdFeed = vm.envAddress("ETH_USD_FEED");

        pool = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(wbtc, weth, POOL_FEE);
        require(pool != address(0), "WBTC/WETH 0.3% pool not found");

        (, int24 currentTick, , , , , ) = IUniswapV3PoolMinimal(pool).slot0();
        int24 spacing = IUniswapV3PoolMinimal(pool).tickSpacing();
        int24 rounded = _roundToSpacing(currentTick, spacing);
        tickLower = rounded - spacing * 100;
        tickUpper = rounded + spacing * 100;

        feeManager    = new FeeManager(treasury, devFund);
        chromaRouter  = new SwapRouter(uniswapRouterAddr);
        chromaRouter.setPriceFeed(wbtc, btcUsdFeed);
        chromaRouter.setPriceFeed(weth, ethUsdFeed);
        chromaRouter.setPoolFee(wbtc, weth, POOL_FEE);

        address[] memory assets = new address[](2);
        assets[0] = wbtc;
        assets[1] = weth;

        strategy = new UniswapV3LPStrategy(
            address(this),     // factory
            address(feeManager),
            assets,
            POSITION_MANAGER,
            pool,
            POOL_FEE,
            tickLower,
            tickUpper,
            address(chromaRouter)
        );
        strategy.registerVault(address(this));

        console2.log("Pool          :", pool);
        console2.log("Current tick  :", currentTick);
        console2.log("tickLower     :", tickLower);
        console2.log("tickUpper     :", tickUpper);
    }

    function _roundToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _dealAndApprove(uint256 wbtcAmount, uint256 wethAmount) internal {
        deal(wbtc, address(this), wbtcAmount);
        deal(weth, address(this), wethAmount);
        IERC20(wbtc).approve(address(strategy), wbtcAmount);
        IERC20(weth).approve(address(strategy), wethAmount);
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ─── deposit ─────────────────────────────────────────────────────────────

    function test_deposit_mintsPosition() public {
        _dealAndApprove(1e8, 20e18); // 1 WBTC + 20 WETH

        uint256 shares = strategy.deposit(_amounts(1e8, 20e18));

        assertGt(shares, 0, "no shares minted");
        assertGt(strategy.tokenId(), 0, "position not minted");
        assertEq(strategy.sharesOf(address(this)), shares);

        (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());
        assertGt(liquidity, 0, "no liquidity in position");

        console2.log("Shares minted :", shares);
        console2.log("Position liquidity:", uint256(liquidity));
    }

    function test_deposit_secondDeposit_increasesExistingPosition() public {
        _dealAndApprove(1e8, 20e18);
        strategy.deposit(_amounts(1e8, 20e18));
        uint256 firstTokenId = strategy.tokenId();

        (, , , , , , , uint128 liquidityBefore, , , , ) = INonfungiblePositionManager(POSITION_MANAGER).positions(firstTokenId);

        _dealAndApprove(1e8, 20e18);
        uint256 shares2 = strategy.deposit(_amounts(1e8, 20e18));

        assertEq(strategy.tokenId(), firstTokenId, "should reuse same position NFT");
        assertGt(shares2, 0, "no shares minted on second deposit");

        (, , , , , , , uint128 liquidityAfter, , , , ) = INonfungiblePositionManager(POSITION_MANAGER).positions(firstTokenId);
        assertGt(liquidityAfter, liquidityBefore, "liquidity did not increase");
    }

    // ─── withdraw ────────────────────────────────────────────────────────────

    function test_withdraw_decreasesProportionally() public {
        _dealAndApprove(1e8, 20e18);
        uint256 shares = strategy.deposit(_amounts(1e8, 20e18));

        (, , , , , , , uint128 liquidityBefore, , , , ) = INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());

        uint256 half = shares / 2;
        uint256[] memory out = strategy.withdraw(half);

        assertGt(out[0] + out[1], 0, "nothing returned from withdraw");
        assertEq(strategy.sharesOf(address(this)), shares - half);

        (, , , , , , , uint128 liquidityAfter, , , , ) = INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());
        assertLt(liquidityAfter, liquidityBefore, "liquidity did not decrease");

        // Roughly half the liquidity should have been removed (within rounding).
        uint256 removedBps = ((uint256(liquidityBefore) - uint256(liquidityAfter)) * 10_000) / uint256(liquidityBefore);
        assertApproxEqAbs(removedBps, 5_000, 100, "expected ~50% liquidity removal");

        console2.log("WBTC out :", out[0]);
        console2.log("WETH out :", out[1]);
    }

    function test_withdraw_fullRedemption_returnsBothTokens() public {
        _dealAndApprove(1e8, 20e18);
        uint256 shares = strategy.deposit(_amounts(1e8, 20e18));

        uint256[] memory out = strategy.withdraw(shares);

        assertGt(out[0], 0, "no WBTC returned");
        assertGt(out[1], 0, "no WETH returned");
        assertEq(strategy.sharesOf(address(this)), 0);
        assertEq(strategy.totalShares(), 0);
    }

    // ─── harvest ─────────────────────────────────────────────────────────────

    function test_harvest_skimsBoostFeeAfterTradingActivity() public {
        _dealAndApprove(5e8, 100e18); // sizeable position to capture a meaningful fee share
        strategy.deposit(_amounts(5e8, 100e18));

        // Generate real trading fees by swapping through the same pool/fee tier.
        deal(weth, address(this), 500e18);
        IERC20(weth).approve(uniswapRouterAddr, 500e18);
        IUniswapRouter(uniswapRouterAddr).exactInputSingle(
            IUniswapRouter.ExactInputSingleParams({
                tokenIn:           weth,
                tokenOut:          wbtc,
                fee:               POOL_FEE,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          500e18,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );

        // Note: positions() only reflects fees as of the position's last mint/burn "touch" —
        // the swap above doesn't update it, so we can't observe accrued fees here without
        // pre-empting the strategy's own poke-then-collect flow inside harvest().
        strategy.harvest();

        uint256 feeWbtc = feeManager.collectedFees(wbtc);
        uint256 feeWeth = feeManager.collectedFees(weth);
        assertTrue(feeWbtc > 0 || feeWeth > 0, "no boost fee forwarded to FeeManager");

        (, , , , , , , , , , uint128 owed0After, uint128 owed1After) =
            INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());
        assertEq(owed0After, 0, "owed0 not fully collected by harvest");
        assertEq(owed1After, 0, "owed1 not fully collected by harvest");

        console2.log("Boost fee WBTC collected:", feeWbtc);
        console2.log("Boost fee WETH collected:", feeWeth);
    }

    // ─── multi-vault redeem / harvest fee isolation ─────────────────────────

    function _generateTradingFees() internal {
        deal(weth, address(this), 500e18);
        IERC20(weth).approve(uniswapRouterAddr, 500e18);
        IUniswapRouter(uniswapRouterAddr).exactInputSingle(
            IUniswapRouter.ExactInputSingleParams({
                tokenIn:           weth,
                tokenOut:          wbtc,
                fee:               POOL_FEE,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          500e18,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function test_redeem_doesNotCollectOtherVaultsFees() public {
        address vaultA = makeAddr("vaultA");
        address vaultB = makeAddr("vaultB");
        strategy.registerVault(vaultA);
        strategy.registerVault(vaultB);

        uint256 wbtcAmt = 1e8;
        uint256 wethAmt = 20e18;

        deal(wbtc, vaultA, wbtcAmt);
        deal(weth, vaultA, wethAmt);
        vm.startPrank(vaultA);
        IERC20(wbtc).approve(address(strategy), wbtcAmt);
        IERC20(weth).approve(address(strategy), wethAmt);
        uint256 sharesA = strategy.deposit(_amounts(wbtcAmt, wethAmt));
        vm.stopPrank();

        deal(wbtc, vaultB, wbtcAmt);
        deal(weth, vaultB, wethAmt);
        vm.startPrank(vaultB);
        IERC20(wbtc).approve(address(strategy), wbtcAmt);
        IERC20(weth).approve(address(strategy), wethAmt);
        strategy.deposit(_amounts(wbtcAmt, wethAmt));
        vm.stopPrank();

        // Generate real, meaningful trading fees on the shared position.
        _generateTradingFees();

        uint256[] memory valueBBefore = strategy.valueOf(vaultB);
        uint256[] memory totalBefore  = strategy.totalAssets();
        uint256 priorTotalShares      = strategy.totalShares();

        // vaultA withdraws part of its stake BEFORE harvest() ever runs.
        uint256 withdrawShares = sharesA / 2;
        vm.prank(vaultA);
        uint256[] memory outA = strategy.withdraw(withdrawShares);

        // Core regression check: vaultB's unrealized fee share must be untouched.
        uint256[] memory valueBAfter = strategy.valueOf(vaultB);
        assertGe(valueBAfter[0], valueBBefore[0], "vaultB WBTC value decreased");
        assertGe(valueBAfter[1], valueBBefore[1], "vaultB WETH value decreased");

        // vaultA's payout must track its proportional PRINCIPAL share only — not be
        // inflated by the trading fees that accrued on the shared position above.
        uint256 expectedWbtc = (totalBefore[0] * withdrawShares) / priorTotalShares;
        uint256 expectedWeth = (totalBefore[1] * withdrawShares) / priorTotalShares;

        console2.log("vaultA WBTC out / expected principal:", outA[0], expectedWbtc);
        console2.log("vaultA WETH out / expected principal:", outA[1], expectedWeth);

        assertApproxEqRel(outA[0], expectedWbtc, 0.02e18, "vaultA payout inflated by fees (WBTC)");
        assertApproxEqRel(outA[1], expectedWeth, 0.02e18, "vaultA payout inflated by fees (WETH)");

        // harvest() must still correctly collect, fee-skim, and re-compound the deferred fees.
        uint256 feeWbtcBefore = feeManager.collectedFees(wbtc);
        uint256 feeWethBefore = feeManager.collectedFees(weth);
        strategy.harvest();
        uint256 feeWbtcAfter = feeManager.collectedFees(wbtc);
        uint256 feeWethAfter = feeManager.collectedFees(weth);

        assertTrue(
            feeWbtcAfter > feeWbtcBefore || feeWethAfter > feeWethBefore,
            "harvest collected no fees after deferred redeem"
        );

        console2.log("Boost fee WBTC from harvest:", feeWbtcAfter - feeWbtcBefore);
        console2.log("Boost fee WETH from harvest:", feeWethAfter - feeWethBefore);
    }

    function test_harvest_doesNotReduceLiquidity() public {
        _dealAndApprove(5e8, 100e18); // sizeable position to capture a meaningful fee share
        strategy.deposit(_amounts(5e8, 100e18));

        _generateTradingFees();

        (, , , , , , , uint128 liquidityBefore, , , , ) =
            INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());

        strategy.harvest();

        (, , , , , , , uint128 liquidityAfter, , , , ) =
            INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());

        assertGe(liquidityAfter, liquidityBefore, "harvest reduced position liquidity");

        console2.log("Liquidity before harvest:", uint256(liquidityBefore));
        console2.log("Liquidity after harvest :", uint256(liquidityAfter));
        console2.log(
            "Liquidity delta         :",
            uint256(liquidityAfter) - uint256(liquidityBefore)
        );
    }

    // ─── emergencyWithdrawAll ────────────────────────────────────────────────

    function test_emergencyWithdrawAll_pullsAllLiquidityAndPauses() public {
        _dealAndApprove(1e8, 20e18);
        strategy.deposit(_amounts(1e8, 20e18));

        uint256 wbtcBefore = IERC20(wbtc).balanceOf(address(strategy));
        uint256 wethBefore = IERC20(weth).balanceOf(address(strategy));

        strategy.emergencyWithdrawAll();

        assertTrue(strategy.paused(), "strategy not paused");

        (, , , , , , , uint128 liquidityAfter, , , uint128 owed0, uint128 owed1) =
            INonfungiblePositionManager(POSITION_MANAGER).positions(strategy.tokenId());
        assertEq(liquidityAfter, 0, "liquidity not fully removed");
        assertEq(owed0, 0, "owed0 not collected");
        assertEq(owed1, 0, "owed1 not collected");

        uint256 wbtcAfter = IERC20(wbtc).balanceOf(address(strategy));
        uint256 wethAfter = IERC20(weth).balanceOf(address(strategy));
        assertGt(wbtcAfter, wbtcBefore, "no WBTC pulled back");
        assertGt(wethAfter, wethBefore, "no WETH pulled back");

        // Further deposits must revert while paused.
        _dealAndApprove(1e8, 20e18);
        vm.expectRevert(YieldOptimizerCore.Paused.selector);
        strategy.deposit(_amounts(1e8, 20e18));
    }
}

/// @dev Minimal slot0()/tickSpacing() accessor — avoids pulling in the full IUniswapV3Pool
///      interface chain just for two read-only calls used in setUp().
interface IUniswapV3PoolMinimal {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
}
