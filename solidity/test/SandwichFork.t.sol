// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {ISwapRouter02} from "../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Sandwich-attack / DOS-cost fork test using the REAL Flow mainnet
///         infrastructure, at a REALISTIC scale: a ~$1M-TVL FCMVault (built
///         from 100 individual $10k deposits, arbed back to clean spot in
///         between, exactly like `IntegrationFork.t.sol`) leaning on the
///         REAL shallow (~$20k liquidity) yield/debt pool.
///
///         Real tokens (WBTC 8 dec / PYUSD0 6 dec / FUSDEV 18 dec), real
///         FlowSwap V3 pool + SwapRouter02, real yield oracle. Only the
///         market oracle is mocked (to simulate the collateral price move
///         that pushes the vault's health factor out of band and into the
///         lever path attackers target).
///
///         Goal: quantify, at realistic TVL,
///           1. How much value a sandwich attacker can extract from a single
///              vault rebalance (`test_Sandwich_SingleSweep_VaultLossBounded`).
///           2. How many rebalance rounds / how long it takes an attacker to
///              push the vault back to a normal health factor, and their
///              net cost for doing so (`test_Sandwich_SoftDOS_...`).
///           3. How much it costs an attacker to relentlessly grief the pool
///              (push 1% + let the vault eat it, 100x) — a DOS cost estimate
///              (`test_Sandwich_HardDOS_...`).
///
///         IMPORTANT — real-pool liquidity is lumpy, not a smooth curve:
///         REAL_POOL (FUSDEV/PYUSD0) is a stable/correlated-asset pool, so its
///         liquidity is concentrated tightly around the current price the way
///         real LPs actually provide it, then falls off a cliff a short
///         distance away — it is NOT the smooth, uniformly-concentrated CPMM
///         curve a synthetic mock would model. `vault.maxSlippageBps` (1%) is
///         a bound on price *impact* relative to the oracle, not a guarantee
///         that 1% of headroom buys a proportional amount of fill. Empirically
///         (`test_Sandwich_SoftDOS_RebalanceUntilNormal`), the lever swap fills
///         fine through ~40bps of attacker push (a few rebalance calls fully
///         re-lever the vault), then the fillable amount collapses by >30x
///         between 40bps and 45bps of push and the vault can no longer
///         reconverge within 100 rebalance calls — because the real liquidity
///         sitting between ~40-100bps of the clean spot is simply much
///         thinner than what's sitting in the first ~40bps. This is a
///         property of THIS pool's actual liquidity distribution on Flow
///         mainnet at fork time, not a fixed protocol constant — it will shift
///         if/when LPs move their ranges. Treat the bps figures here as a
///         snapshot, not a hard guarantee.
///
///         Forks Flow mainnet directly (no env var needed).
contract SandwichForkTest is Test {
    IERC20 constant WBTC = IERC20(0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);

    // Real production band.
    uint256 constant HEALTH_FACTOR_MIN = 1_228_571_428_571_428_571;
    uint256 constant HEALTH_FACTOR_MIN_TARGET = 1_230_329_041_487_839_771;
    uint256 constant HEALTH_FACTOR_MAX = 1_433_333_333_333_333_333;
    uint256 constant HEALTH_FACTOR_MAX_TARGET = 1_430_948_419_301_164_725;
    uint256 constant YIELD_FACTOR_MAX = 1.01e18;

    address internal collateralLoanPool;

    address constant MARKET_ORACLE = 0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8;
    address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;
    uint256 constant MARKET_LLTV = 0.86e18;
    IOracle constant YIELD_ORACLE = IOracle(0x144F613490DD55C9844Ef139CFB9B63433dD349F);

    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    address constant REAL_POOL = 0x9196e243b7562B0866309013f2F9EB63F83A690f;


    uint24 constant COLLATERAL_LOAN_POOL_FEE = 3000;
    uint24 constant YIELD_LOAN_POOL_FEE = 100;

    // ~$1M TVL from 100 individual $10k deposits (0.1 WBTC each at
    // ~$100k/BTC), each arbed back to the pool's clean spot afterwards — the
    // same realistic build-up used in IntegrationFork.t.sol. This is the
    // scale that matters for a sandwich/DOS analysis: a real vault sized far
    // above the ~$20k pool it swaps through.
    uint256 constant N_USERS = 100;
    uint256 constant DEPOSIT_AMOUNT_PER_USER = 0.1e8; // 0.1 WBTC (8 decimals)

    FCMVault internal vault;
    MarketParams internal mp;
    Id internal marketId;
    uint256 internal realPrice;
    uint256 internal snap;
    uint160 internal cleanSpot;

    address internal admin = address(this);
    address[] internal users;
    address internal attacker = makeAddr("attacker");
    address internal arb = makeAddr("arb");

    struct SandwichResult {
        int256 attackerProfit; // PYUSD0 raw (6 dec)
        uint256 debtAdded; // PYUSD0 raw (6 dec)
        uint256 yieldBought; // FUSDEV raw (18 dec)
        uint256 hfAfter;
        uint256 tvlUsd; // PYUSD0 raw (6 dec)
    }

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        // ── Read real oracle price
        // ──────────────────────────────────────────
        try IOracle(MARKET_ORACLE).price() returns (uint256 p) {
            realPrice = p;
        } catch {
            realPrice = 1e39; // WBTC ~$100k fallback
        }
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(realPrice));

        // ── Market params
        // ──────────────────────────────────────────────────
        mp = MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WBTC),
            oracle: MARKET_ORACLE,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
        marketId = MarketParamsLib.id(mp);

        // ── Collateral/loan pool from factory
        // ───────────────────────────────────
        collateralLoanPool = _getPool(SWAP_FACTORY, address(WBTC), address(PYUSD0), COLLATERAL_LOAN_POOL_FEE);
        require(collateralLoanPool != address(0), "WBTC/PYUSD0 pool missing");

        // ── Supply PYUSD0 to the real Morpho market (needs liquidity) ──────
        // $1M TVL levers roughly $650k of debt at the deposit-target HF, plus
        // headroom for lever-up rebalances during the attacks below.
        Market memory mkt = MarketLib.MORPHO.market(marketId);
        if (mkt.totalSupplyAssets < 5_000_000e6) {
            address supplier = makeAddr("supplier");
            deal(address(PYUSD0), supplier, 10_000_000e6);
            vm.startPrank(supplier);
            PYUSD0.approve(address(MarketLib.MORPHO), type(uint256).max);
            MarketLib.MORPHO.supply(mp, 10_000_000e6, 0, supplier, "");
            vm.stopPrank();
        }

        // ── Read real pool spot
        // ───────────────────────────────────────────
        (cleanSpot,,,,,,) = IUniswapV3Pool(REAL_POOL).slot0();

        // ── Deploy FCMVault with real production config
        // ────────────────────
        vault = new FCMVault(
            IFCMVault.InitParams({
                collateralToken: WBTC,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
                yieldFactorMax: YIELD_FACTOR_MAX,
                collateralLoanPool: collateralLoanPool,
                collateralLoanPoolFee: COLLATERAL_LOAN_POOL_FEE,
                yieldLoanPool: REAL_POOL,
                yieldLoanPoolFee: YIELD_LOAN_POOL_FEE,
                marketOracle: MARKET_ORACLE,
                marketIrm: MARKET_IRM,
                marketLltv: MARKET_LLTV,
                yieldOracle: YIELD_ORACLE,
                owner: admin,
                name: "fcmWBTC-sandwich-fork",
                symbol: "fcmWBTC-SF"
            })
        );
        vault.setMaxTvl(type(uint256).max);
        // maxSlippageBps defaults to 0 (not in InitParams); set the 1% production
        // default here so rebalance swaps don't no-op against an off-oracle pool.
        vault.setMaxSlippageBps(100);

        // ── Fund the arb bot up front (needed during the deposit build-up) ──
        deal(address(PYUSD0), arb, 100_000_000e6);
        deal(address(FUSDEV), arb, 100_000_000e18);
        vm.startPrank(arb);
        PYUSD0.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();

        // ── Build ~$1M TVL from 100 individual deposits through the REAL
        //    pool, arbing back to clean spot after each (a real market would
        //    re-equilibrate between deposits)
        // ───────────────────────────────
        users = new address[](N_USERS);
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users[i] = u;
            vault.grantEarlyAccess(u);
            deal(address(WBTC), u, DEPOSIT_AMOUNT_PER_USER);

            vm.startPrank(u);
            WBTC.approve(address(vault), DEPOSIT_AMOUNT_PER_USER);
            vault.deposit(DEPOSIT_AMOUNT_PER_USER, u);
            vm.stopPrank();

            _arbPoolToSpot();
        }

        // ── Push the collateral price +10% -> HF above max -> lever path ───
        uint256 raisedPrice = realPrice * 110 / 100;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(raisedPrice));
        assertGt(_hf(), HEALTH_FACTOR_MAX, "HF above max after 10% rise -> lever path");

        // ── Fund attacker with real tokens via deal
        // ────────────────────────
        deal(address(PYUSD0), attacker, 100_000_000e6);
        deal(address(FUSDEV), attacker, 100_000_000e18);
        vm.startPrank(attacker);
        PYUSD0.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();

        // ── Snapshot
        // ───────────────────────────────────────────────────────
        snap = vm.snapshotState();

        console.log("=== Sandwich fork test setup ($1M TVL vs ~$20k pool) ===");
        console.log("Real price:", realPrice);
        console.log("Yield oracle:", IOracle(YIELD_ORACLE).price());
        console.log("Pool spot:", uint256(cleanSpot));
        console.log("Pool liquidity:", uint256(IUniswapV3Pool(REAL_POOL).liquidity()));
        console.log("HF after 10% rise:", _hf() / 1e15);
        console.log("TVL ($):", _tvlUsd() / 1e6);
        console.log("---");

        _arbPoolToSpot();
    }

    // =====================================================================
    // Test 1: Single-sandwich sweep — how much can be extracted from one
    //         vault rebalance at realistic ($1M) TVL?
    // =====================================================================

    function test_Sandwich_SingleSweep_VaultLossBounded() public {
        console.log("=== Single sandwich sweep: 0.05% to 0.95% push (REAL pool, $1M TVL) ===");
        console.log("pushBps | attackerProfit($) | debtAdded(PYUSD) | yieldBought(mFUSDEV) | overpayBps | tvl$");

        uint256 maxOverpayBps = 0;
        int256 maxAttackerProfit = type(int256).min;

        for (uint256 i = 1; i <= 19; i++) {
            uint256 pushBps = i * 5;
            vm.revertToState(snap);
            _arbPoolToSpot();

            SandwichResult memory r = _singleSandwich(pushBps);

            // Vault overpayment: debt (PYUSD0, 6 dec) vs yield valued at oracle.
            uint256 yieldInPyUsd = Math.mulDiv(r.yieldBought, IOracle(YIELD_ORACLE).price(), 1e36);
            uint256 overpay = r.debtAdded > yieldInPyUsd ? r.debtAdded - yieldInPyUsd : 0;
            uint256 overpayBps = r.debtAdded > 0 ? overpay * 10_000 / r.debtAdded : 0;
            if (overpayBps > maxOverpayBps) maxOverpayBps = overpayBps;
            if (r.attackerProfit > maxAttackerProfit) maxAttackerProfit = r.attackerProfit;

            if (pushBps <= 50) {
                assertGt(r.debtAdded, 0, "vault rebalanced at low push");
            }

            string memory profitStr = r.attackerProfit >= 0
                ? string.concat("profit=$", vm.toString(uint256(r.attackerProfit) / 1e6))
                : string.concat("profit=-$", vm.toString(uint256(-r.attackerProfit) / 1e6));
            console.log(
                string.concat(
                    "push=",
                    vm.toString(pushBps),
                    "bps | ",
                    profitStr,
                    " | debt+=",
                    vm.toString(r.debtAdded / 1e6),
                    " | yield+=",
                    vm.toString(r.yieldBought / 1e15),
                    "m | overpay=",
                    vm.toString(overpayBps),
                    "bps | tvl=$",
                    vm.toString(r.tvlUsd / 1e6)
                )
            );
        }

        console.log("---");
        console.log("Max vault overpayment:", maxOverpayBps, "bps");
        console.log("Max single-sweep attacker profit ($):", maxAttackerProfit >= 0 ? maxAttackerProfit / 1e6 : -1);
        // Vault overpayment per rebalance call is bounded by maxSlippageBps
        // (1%) regardless of TVL -- the AMM's price-impact bound, not the
        // vault's size, caps the damage from a single sandwiched rebalance.
        assertLe(maxOverpayBps, 100, "vault overpayment <= 1% even at $1M TVL");
    }

    // =====================================================================
    // Test 2: Soft DOS — rebalance until normal HF or 100 iterations.
    //         How many rounds (and what net cost) does an attacker need to
    //         keep sandwiching every rebalance call until the vault is back
    //         to a normal health factor?
    //
    //         At fork time, expect iterations to jump sharply around
    //         push=40-45bps (a few iterations below it, 100 -- i.e. it never
    //         reconverges -- at/above it). That cliff is the real pool's
    //         liquidity distribution, not a maxSlippageBps discontinuity: see
    //         the "IMPORTANT" note in the contract-level doc comment above.
    // =====================================================================

    function test_Sandwich_SoftDOS_RebalanceUntilNormal() public {
        console.log("=== Soft DOS: rebalance until normal HF or 100 iterations ($1M TVL) ===");
        console.log("pushBps | iterations | attackerNet($) | hfFinal | tvl$");

        for (uint256 i = 1; i <= 19; i++) {
            uint256 pushBps = i * 5;
            vm.revertToState(snap);
            _arbPoolToSpot();

            int256 totalProfit = 0;
            uint256 iterations = 0;
            uint256 hfFinal = 0;
            uint256 tvlFinal = 0;

            for (uint256 y = 0; y < 100; y++) {
                SandwichResult memory r = _singleSandwich(pushBps);
                totalProfit += r.attackerProfit;
                iterations = y + 1;
                hfFinal = r.hfAfter;
                tvlFinal = r.tvlUsd;
                _arbPoolToSpot();
                if (r.hfAfter <= HEALTH_FACTOR_MAX) break;
            }

            string memory netStr = totalProfit >= 0
                ? string.concat("+$", vm.toString(SafeCast.toUint256(totalProfit) / 1e6))
                : string.concat("-$", vm.toString(SafeCast.toUint256(-totalProfit) / 1e6));
            console.log(
                string.concat(
                    "push=",
                    vm.toString(pushBps),
                    "bps | iters=",
                    vm.toString(iterations),
                    " | attacker=",
                    netStr,
                    " | hf=",
                    vm.toString(hfFinal / 1e15),
                    " | tvl=$",
                    vm.toString(tvlFinal / 1e6)
                )
            );
            assertLt(totalProfit, 100e6, "total profit > $100");
        }
    }

    // =====================================================================
    // Test 3: Hard DOS — push 1% 100 times.
    //         Estimates the attacker's out-of-pocket cost to relentlessly
    //         grief the vault's rebalance path at realistic TVL.
    // =====================================================================

    function test_Sandwich_HardDOS_Push1Percent_100Times() public {
        vm.revertToState(snap);
        _arbPoolToSpot();

        int256 totalProfit = 0;
        uint256 debtAdded = 0;
        uint256 hfFinal = 0;

        for (uint256 y = 0; y < 100; y++) {
            SandwichResult memory r = _singleSandwich(100);
            totalProfit += r.attackerProfit;
            hfFinal = r.hfAfter;
            debtAdded += r.debtAdded;
            _arbPoolToSpot();
        }

        uint256 attackerCost = totalProfit < 0 ? SafeCast.toUint256(-totalProfit) : 0;
        console.log("Hard DOS (100x push 1%, REAL pool, $1M TVL): attacker cost = $", attackerCost / 1e6);
        console.log("Vault debt added:", debtAdded / 1e6, "PYUSD");
        console.log("Vault HF final:", hfFinal / 1e15);
    }

    // =====================================================================
    // Core sandwich helper — REAL SwapRouter + REAL pool
    // =====================================================================

    function _singleSandwich(uint256 pushBps) internal returns (SandwichResult memory r) {
        uint256 debtStart = _debt();
        uint256 yieldStart = FUSDEV.balanceOf(address(vault));

        (uint160 currentSpot,,,,,,) = IUniswapV3Pool(REAL_POOL).slot0();

        // Compute target pushed spot: currentSpot * sqrt(1 - pushBps/10000).
        uint256 sqrtFactor = Math.sqrt((10_000 - pushBps) * 1e36 / 10_000);
        uint160 targetSpot = uint160(Math.mulDiv(currentSpot, sqrtFactor, 1e18));
        // uint160 targetSpot = uint160(uint256(currentSpot) * sqrtFactor / 1e18);

        uint256 loanBefore = PYUSD0.balanceOf(attacker);

        // 1) FRONT-RUN: sell PYUSD0 → FUSDEV through real pool.
        uint256 yieldGotFront = 0;
        if (pushBps > 0) {
            vm.prank(attacker);
            yieldGotFront = ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: attacker,
                    amountIn: 100_000_000e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        }

        // 2) VICTIM: vault rebalances through real pool.
        vault.rebalance();
        r.debtAdded = _debt() - debtStart;
        r.yieldBought = FUSDEV.balanceOf(address(vault)) - yieldStart;
        r.hfAfter = _hf();
        r.tvlUsd = _tvlUsd();

        // 3) BACK-RUN: sell FUSDEV → PYUSD0 through real pool.
        if (yieldGotFront > 0) {
            vm.prank(attacker);
            ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(FUSDEV),
                    tokenOut: address(PYUSD0),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: attacker,
                    amountIn: yieldGotFront,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
                );
        }

        r.attackerProfit = int256(int256(PYUSD0.balanceOf(attacker)) - SafeCast.toInt256(loanBefore));
    }

    // =====================================================================
    // Arb helper — restore real pool to clean spot
    // =====================================================================

    function _arbPoolToSpot() internal {
        (uint160 currentSpot,,,,,,) = IUniswapV3Pool(REAL_POOL).slot0();
        if (currentSpot < cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(FUSDEV),
                    tokenOut: address(PYUSD0),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 100_000_000e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        } else if (currentSpot > cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 100_000_000e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        }
    }

    // =====================================================================
    // Vault read helpers
    // =====================================================================

    function _tvlUsd() internal view returns (uint256) {
        return Math.mulDiv(vault.totalAssets(), IOracle(MARKET_ORACLE).price(), 1e36);
    }

    function _hf() internal view returns (uint256) {
        Position memory pos = MarketLib.MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return type(uint256).max;
        Market memory mkt = MarketLib.MORPHO.market(marketId);
        uint256 debt = Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets) + 1,
            uint256(mkt.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
        uint256 maxBorrow =
            Math.mulDiv(uint256(pos.collateral), Math.mulDiv(IOracle(MARKET_ORACLE).price(), MARKET_LLTV, 1e36), 1e18);
        return Math.mulDiv(maxBorrow, 1e18, debt);
    }

    function _debt() internal view returns (uint256) {
        Position memory pos = MarketLib.MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MarketLib.MORPHO.market(marketId);
        return Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets) + 1,
            uint256(mkt.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
    }

    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSelector(0x1698ee82, tokenA, tokenB, fee));
        require(ok, "factory call failed");
        return abi.decode(data, (address));
    }
}
