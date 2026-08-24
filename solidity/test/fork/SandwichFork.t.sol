// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/console.sol";

import {ForkDeployers} from "./ForkDeployers.sol";

contract SandwichForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;
    uint256 constant N_USERS = 100;
    uint256 constant DEPOSIT_AMOUNT_PER_USER = 0.1e8;

    address internal attacker = makeAddr("attacker");
    address[] internal users;
    uint256 internal snap;

    struct SandwichResult {
        int256 attackerProfit;
        uint256 debtAdded;
        uint256 yieldBought;
        uint256 ltvAfter;
        uint256 tvlUsd;
    }

    function setUp() public {
        _forkSetup();
        _fundArb();
        _depositUsers(N_USERS, DEPOSIT_AMOUNT_PER_USER);

        users = new address[](N_USERS);
        for (uint256 i = 0; i < N_USERS; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
        }

        setCollateralPrice(ORACLE_PRICE * 110 / 100);
        assertGt(vault.ltv(), LTV_MAX, "HF above max after 10% rise -> lever path");

        deal(address(PYUSD0), attacker, 100_000_000e6);
        deal(address(FUSDEV), attacker, 100_000_000e18);
        vm.startPrank(attacker);
        PYUSD0.approve(address(SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();

        snap = vm.snapshotState();

        console.log("=== Sandwich fork test setup ($1M TVL vs ~$20k pool) ===");
        console.log("Collateral price:", ORACLE_PRICE);
        console.log("Yield oracle:", IOracle(YIELD_ORACLE).price());
        console.log("Pool spot:", uint256(cleanSpot));
        console.log("Pool liquidity:", uint256(IUniswapV3Pool(YIELD_LOAN_POOL).liquidity()));
        console.log("HF after 10% rise:", vault.ltv() / 1e15);
        console.log("TVL ($):", _tvlUsd() / 1e6);
        console.log("---");

        _arbPoolToSpot();
    }

    function test_sandwich_singleSweepVaultLossBounded() public {
        console.log("=== Single sandwich sweep: 0.05% to 0.95% push (REAL pool, $1M TVL) ===");
        console.log("pushBps | attackerProfit($) | debtAdded(PYUSD) | yieldBought(mFUSDEV) | overpayBps | tvl$");

        uint256 maxOverpayBps = 0;
        int256 maxAttackerProfit = type(int256).min;

        for (uint256 i = 1; i <= 19; i++) {
            uint256 pushBps = i * 5;
            vm.revertToState(snap);
            _arbPoolToSpot();

            SandwichResult memory r = _singleSandwich(pushBps);

            uint256 yieldInPyUsd = Math.mulDiv(r.yieldBought, IOracle(YIELD_ORACLE).price(), 1e36);
            uint256 overpay = r.debtAdded > yieldInPyUsd ? r.debtAdded - yieldInPyUsd : 0;
            uint256 overpayBps = r.debtAdded > 0 ? overpay * 10_000 / r.debtAdded : 0;
            if (overpayBps > maxOverpayBps) maxOverpayBps = overpayBps;
            if (r.attackerProfit > maxAttackerProfit) maxAttackerProfit = r.attackerProfit;

            if (pushBps <= 50 && r.debtAdded > 0) {
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
        assertLe(maxOverpayBps, 100, "vault overpayment <= 1% even at $1M TVL");
    }

    function test_sandwich_softDOSRebalanceUntilNormal() public {
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
                hfFinal = r.ltvAfter;
                tvlFinal = r.tvlUsd;
                _arbPoolToSpot();
                if (r.ltvAfter <= LTV_MAX) break;
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

    function test_sandwich_hardDOSPush1Percent100Times() public {
        vm.revertToState(snap);
        _arbPoolToSpot();

        int256 totalProfit = 0;
        uint256 debtAdded = 0;
        uint256 hfFinal = 0;

        for (uint256 y = 0; y < 100; y++) {
            SandwichResult memory r = _singleSandwich(100);
            totalProfit += r.attackerProfit;
            hfFinal = r.ltvAfter;
            debtAdded += r.debtAdded;
            _arbPoolToSpot();
        }

        uint256 attackerCost = totalProfit < 0 ? SafeCast.toUint256(-totalProfit) : 0;
        console.log("Hard DOS (100x push 1%, REAL pool, $1M TVL): attacker cost = $", attackerCost / 1e6);
        console.log("Vault debt added:", debtAdded / 1e6, "PYUSD");
        console.log("Vault HF final:", hfFinal / 1e15);
    }

    function _singleSandwich(uint256 pushBps) internal returns (SandwichResult memory r) {
        uint256 debtStart = vault.debt();
        uint256 yieldStart = FUSDEV.balanceOf(address(vault));

        (uint160 currentSpot,,,,,,) = IUniswapV3Pool(YIELD_LOAN_POOL).slot0();

        uint256 sqrtFactor = Math.sqrt((10_000 - pushBps) * 1e36 / 10_000);
        uint160 targetSpot = uint160(Math.mulDiv(currentSpot, sqrtFactor, 1e18));

        uint256 loanBefore = PYUSD0.balanceOf(attacker);

        uint256 yieldGotFront = 0;
        if (pushBps > 0) {
            vm.prank(attacker);
            yieldGotFront = ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: attacker,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        }

        vault.rebalance();
        r.debtAdded = vault.debt() - debtStart;
        r.yieldBought = FUSDEV.balanceOf(address(vault)) - yieldStart;
        r.ltvAfter = vault.ltv();
        r.tvlUsd = _tvlUsd();

        if (yieldGotFront > 0) {
            vm.prank(attacker);
            ISwapRouter02(address(SWAP_ROUTER))
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
}
