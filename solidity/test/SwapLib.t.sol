// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Deployers} from "./utils/Deployers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        YIELD_LOAN_POOL.setPrice(YIELD_TOKEN, LOAN_TOKEN, oraclePrice);

        bool zeroForOne = address(YIELD_TOKEN) < address(LOAN_TOKEN);
        (uint256 floorNum, uint256 floorDen, uint256 ceilNum, uint256 ceilDen) = _bounds(zeroForOne, oraclePrice, 1e36);

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: YIELD_LOAN_POOL,
            tokenIn: YIELD_TOKEN,
            tokenOut: LOAN_TOKEN,
            outPerInNum: oraclePrice,
            outPerInDen: 1e36,
            maxSlippageBps: maxSlippageBps
        });

        assertGe(priceLimit, _sqrtPriceX96(floorNum, floorDen));
        assertLe(priceLimit, _sqrtPriceX96(ceilNum, ceilDen));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitLoanYield(uint256 maxSlippageBps, uint256 oraclePrice) public {
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        oraclePrice = bound(oraclePrice, 1e30, 1e40);
        YIELD_LOAN_POOL.setPrice(LOAN_TOKEN, YIELD_TOKEN, uint256(1e36).mulDiv(1e36, oraclePrice));

        bool zeroForOne = address(LOAN_TOKEN) < address(YIELD_TOKEN);
        (uint256 floorNum, uint256 floorDen, uint256 ceilNum, uint256 ceilDen) = _bounds(zeroForOne, 1e36, oraclePrice);

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: YIELD_LOAN_POOL,
            tokenIn: LOAN_TOKEN,
            tokenOut: YIELD_TOKEN,
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });

        assertGe(priceLimit, _sqrtPriceX96(floorNum, floorDen));
        assertLe(priceLimit, _sqrtPriceX96(ceilNum, ceilDen));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitCollateralLoan(uint256 maxSlippageBps, uint256 oraclePrice) public {
        maxSlippageBps = uint256(bound(maxSlippageBps, 1, 9999));
        oraclePrice = bound(oraclePrice, 1e30, 1e40);
        COLLATERAL_LOAN_POOL.setPrice(LOAN_TOKEN, COLLATERAL_TOKEN, uint256(1e36).mulDiv(1e36, oraclePrice));

        bool zeroForOne = address(LOAN_TOKEN) < address(COLLATERAL_TOKEN);
        (uint256 floorNum, uint256 floorDen, uint256 ceilNum, uint256 ceilDen) = _bounds(zeroForOne, 1e36, oraclePrice);

        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: IUniswapV3Pool(address(COLLATERAL_LOAN_POOL)),
            tokenIn: LOAN_TOKEN,
            tokenOut: COLLATERAL_TOKEN,
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });

        assertGe(priceLimit, _sqrtPriceX96(floorNum, floorDen));
        assertLe(priceLimit, _sqrtPriceX96(ceilNum, ceilDen));
        assertEq(ok, true);
    }

    function testFuzz_swapLib_priceLimitYieldLoanSkipWhenPoolPastBound(uint256 maxSlippageBps, uint256 oraclePrice)
        public
    {
        oraclePrice = bound(oraclePrice, 5e35, 15e35);
        maxSlippageBps = bound(maxSlippageBps, 1, 9999);
        YIELD_LOAN_POOL.setPrice(YIELD_TOKEN, LOAN_TOKEN, oraclePrice.mulDiv(10_000 - maxSlippageBps, 10_000));

        (, bool ok) = SwapLib.swapLimit({
            pool: YIELD_LOAN_POOL,
            tokenIn: YIELD_TOKEN,
            tokenOut: LOAN_TOKEN,
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
            LOAN_TOKEN, YIELD_TOKEN, uint256(1e36).mulDiv(1e36, oraclePrice).mulDiv(10_000 - maxSlippageBps, 10_000)
        );
        (, bool ok) = SwapLib.swapLimit({
            pool: YIELD_LOAN_POOL,
            tokenIn: LOAN_TOKEN,
            tokenOut: YIELD_TOKEN,
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: maxSlippageBps
        });
        assertFalse(ok);
    }

    function testFuzz_swapLib_priceLimitCollateralLoanSkipWhenPoolPastBound(uint256 oraclePrice) public {
        oraclePrice = bound(oraclePrice, 5e35, 15e35);
        COLLATERAL_LOAN_POOL.setPrice(
            LOAN_TOKEN, COLLATERAL_TOKEN, uint256(1e36).mulDiv(1e36, oraclePrice).mulDiv(100, 103)
        );
        (, bool ok) = SwapLib.swapLimit({
            pool: IUniswapV3Pool(COLLATERAL_LOAN_POOL),
            tokenIn: LOAN_TOKEN,
            tokenOut: COLLATERAL_TOKEN,
            outPerInNum: 1e36,
            outPerInDen: oraclePrice,
            maxSlippageBps: 100
        });
        assertFalse(ok);
    }

    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.sqrt(Math.mulDiv(num, 1 << 192, den));
    }

    /// @dev Computes the floor and ceiling sqrtPriceX96 bounds for `swapLimit`, accounting for which branch
    /// (`zeroForOne`) the function will take. `num`/`den` are the outPerIn fraction (tokenOut per tokenIn) AS
    /// PASSED to swapLimit. `swapLimit` internally swaps them to token1/token0 for `zeroForOne=false`, so this
    /// helper mirrors that swap before computing the bounds. Floor = fair price (slip=0), ceiling = max slip (9999).
    function _bounds(bool zeroForOne, uint256 num, uint256 den)
        internal
        pure
        returns (uint256 floorNum, uint256 floorDen, uint256 ceilNum, uint256 ceilDen)
    {
        if (!zeroForOne) (num, den) = (den, num);

        if (zeroForOne) {
            floorNum = num;
            floorDen = den * 10_000;
            ceilNum = num;
            ceilDen = den;
        } else {
            floorNum = num;
            floorDen = den;
            ceilNum = num * 10_000;
            ceilDen = den;
        }
    }

    function test_swapLib_skipWhenFairRateBelowMinSqrtRatio() public view {
        (uint160 priceLimit, bool ok) = SwapLib.swapLimit({
            pool: YIELD_LOAN_POOL,
            tokenIn: IERC20(address(0x01)),
            tokenOut: IERC20(address(0x02)),
            outPerInNum: 0,
            outPerInDen: 1e36,
            maxSlippageBps: 100
        });

        assertEq(priceLimit, 0);
        assertFalse(ok);
    }
}
