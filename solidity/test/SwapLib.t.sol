// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract SwapLibTest is Test, Deployers {
    using Math for uint256;

    function setUp() public {
        deployVault();
    }

    function testFuzz_swapLib_priceLimitYieldLoan(uint256 maxSlippageBps, uint256 oraclePrice) public {
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        oraclePrice = bound(oraclePrice, 1e30, 1e40);
        YIELD_LOAN_POOL.setPrice(address(YIELD_TOKEN), address(LOAN_TOKEN), oraclePrice);

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(YIELD_TOKEN),
            tokenOut: address(LOAN_TOKEN),
            outPerInNum: oraclePrice,
            outPerInDen: 1e36,
            maxSlippageBps: maxSlippageBps
        });

        // Floor bound uses the same single-mulDiv shape swapLimit itself uses (at the loosest bps = 1), instead of
        // pre-dividing oraclePrice by 9999/10_000 first - pre-dividing floors twice and, at extreme oraclePrice
        // magnitudes, can round the floor above the actual (single-mulDiv) priceLimit.
        assertGe(priceLimit, _sqrtPriceX96(1e36 * 10_000, oraclePrice * 9999));
        assertLe(priceLimit, _sqrtPriceX96(1e36 * 10_000, oraclePrice * (10_000 - maxSlippageBps)));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitLoanYield(uint256 maxSlippageBps, uint256 oraclePrice) public {
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        oraclePrice = bound(oraclePrice, 1e30, 1e40);
        YIELD_LOAN_POOL.setPrice(address(LOAN_TOKEN), address(YIELD_TOKEN), uint256(1e36).mulDiv(1e36, oraclePrice));

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(LOAN_TOKEN),
            tokenOut: address(YIELD_TOKEN),
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });

        assertGe(priceLimit, _sqrtPriceX96(1e36 * (10_000 - maxSlippageBps), oraclePrice * 10_000));
        assertLe(priceLimit, _sqrtPriceX96(1e36, oraclePrice));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitCollateralLoan(uint256 maxSlippageBps, uint256 oraclePrice) public {
        maxSlippageBps = uint256(bound(maxSlippageBps, 1, 9999));
        oraclePrice = bound(oraclePrice, 1e30, 1e40);
        COLLATERAL_LOAN_POOL.setPrice(
            address(LOAN_TOKEN), address(COLLATERAL_TOKEN), uint256(1e36).mulDiv(1e36, oraclePrice)
        );

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: address(COLLATERAL_LOAN_POOL),
            tokenIn: address(LOAN_TOKEN),
            tokenOut: address(COLLATERAL_TOKEN),
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });

        assertGe(priceLimit, _sqrtPriceX96(oraclePrice * 10_000, 1e36 * (10_000 - 1)));
        assertLe(priceLimit, _sqrtPriceX96(oraclePrice * 10_000, 1e36 * (10_000 - maxSlippageBps)));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitYieldLoanSkipWhenPoolPastBound(uint256 maxSlippageBps, uint256 oraclePrice)
        public
    {
        oraclePrice = bound(oraclePrice, 5e35, 15e35);
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        YIELD_LOAN_POOL.setPrice(
            address(YIELD_TOKEN), address(LOAN_TOKEN), oraclePrice.mulDiv(10_000 - maxSlippageBps, 10_000)
        );

        (, bool ok) = SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(YIELD_TOKEN),
            tokenOut: address(LOAN_TOKEN),
            outPerInNum: oraclePrice,
            outPerInDen: 1e36,
            maxSlippageBps: maxSlippageBps
        });
        assertFalse(ok);
    }

    function testFuzz_swapLib_priceLimitLoanYieldSkipWhenPoolPastBound(uint256 maxSlippageBps, uint256 oraclePrice)
        public
    {
        oraclePrice = bound(oraclePrice, 5e35, 15e35);
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        YIELD_LOAN_POOL.setPrice(
            address(LOAN_TOKEN),
            address(YIELD_TOKEN),
            uint256(1e36).mulDiv(1e36, oraclePrice).mulDiv(10_000 - maxSlippageBps, 10_000)
        );
        (, bool ok) = SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(LOAN_TOKEN),
            tokenOut: address(YIELD_TOKEN),
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });
        assertFalse(ok);
    }

    function testFuzz_swapLib_priceLimitCollateralLoanSkipWhenPoolPastBound(uint256 oraclePrice) public {
        oraclePrice = bound(oraclePrice, 5e35, 15e35);
        COLLATERAL_LOAN_POOL.setPrice(
            address(LOAN_TOKEN), address(COLLATERAL_TOKEN), uint256(1e36).mulDiv(1e36, oraclePrice).mulDiv(100, 103)
        );
        (, bool ok) = SwapLib.swapLimit({
            pool: address(COLLATERAL_LOAN_POOL),
            tokenIn: address(LOAN_TOKEN),
            tokenOut: address(COLLATERAL_TOKEN),
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: 100
        });
        assertFalse(ok);
    }

    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.sqrt(Math.mulDiv(num, 1 << 192, den));
    }

    function test_swapLib_skipWhenFairRateBelowMinSqrtRatio() public view {
        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(0x01),
            tokenOut: address(0x02),
            outPerInNum: 0,
            outPerInDen: 1e36,
            maxSlippageBps: 100
        });

        assertEq(priceLimit, 0);
        assertFalse(ok);
    }

    // Documents that the `raw >= MAX_SQRT_RATIO` guard is DEAD CODE: satisfying it
    // requires `mulDiv(num, 2^192, den) >= (MAX_SQRT_RATIO)^2 ~= 2.14e96`, which
    // exceeds `type(uint256).max` (~1.16e77), so `Math.mulDiv` reverts with an
    // arithmetic-overflow panic (0x11) BEFORE the comparison can return `(0, false)`.
    // Any fair rate large enough to clear the ceiling therefore aborts `swapLimit`
    // rather than gracefully skipping — a latent graceful-skip gap for pathological
    // oracle prices (see TEST_GAPS.md). With realistic 1e36-scale oracle prices the
    // ratio is ~1, so this never triggers in practice.
    function test_swapLib_revertsWhenFairRateWouldExceedMaxSqrtRatio() public {
        // ratio = outPerInNum/outPerInDen = 1e60/1 -> mulDiv result ~ 1e60 * 2^192 ~ 6.3e117 >> 2^256.
        // Panic(uint256) selector 0x4e487b71, code 0x11 = arithmetic overflow/underflow.
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)));
        SwapLib.swapLimit({
            pool: address(YIELD_LOAN_POOL),
            tokenIn: address(0x01),
            tokenOut: address(0x02),
            outPerInNum: 1e60,
            outPerInDen: 1,
            maxSlippageBps: 100
        });
    }
}
