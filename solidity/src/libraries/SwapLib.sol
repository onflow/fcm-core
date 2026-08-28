// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {BPS} from "./ConstantsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SwapLib
/// @author Flow Foundation
/// @notice Thin wrapper around SwapRouter02. Recipient is always `address(this)`.
library SwapLib {
    /// @dev Uniswap V3 tick-math bound on a valid `sqrtPriceLimitX96`.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    /// @dev Uniswap V3 tick-math bound on a valid `sqrtPriceLimitX96`.
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev Q64.96 fixed-point one squared (`2**192`)
    uint256 internal constant ONE_X192 = 1 << 192;

    /// @notice Swap tokenIn for tokenOut
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being bought.
    /// @param amountInRequested Maximum amount of `tokenIn` to sell.
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot move beyond this limit.
    /// @return amountIn Realized amount of `tokenIn` spent (<= `amountInRequested` on a partial fill).
    /// @return amountOut Realized amount of `tokenOut` received.
    function swapExactInToLimit(
        IUniswapV3Pool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountInRequested,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        uint160 limit = _setUnsetLimit(sqrtPriceLimitX96, zeroForOne);
        bytes memory data = abi.encode(address(tokenIn));
        // casting is safe because will only use tokens with supply well below 2**256
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 a0, int256 a1) = pool.swap(address(this), zeroForOne, int256(amountInRequested), limit, data);
        // Positive delta = pool received (input consumed); negative delta = pool sent (output).
        // On a partial fill the consumed input is LESS than `amountInRequested` - the unspent input stays with the
        // caller. casting to 'uint256' is safe because uniswap return convention
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = zeroForOne ? uint256(a0) : uint256(a1);
        // casting to 'uint256' is safe because uniswap return convention
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = zeroForOne ? uint256(-a1) : uint256(-a0);
    }

    /// @notice Swap tokenIn for tokenOut
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being bought.
    /// @param amountOutRequested Maximum amount of `tokenOut` to receive.
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot move beyond this limit.
    /// @return amountIn Realized amount of `tokenIn` spent.
    /// @return amountOut Realized amount of `tokenOut` received.
    function swapExactOutToLimit(
        IUniswapV3Pool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountOutRequested,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        uint160 limit = _setUnsetLimit(sqrtPriceLimitX96, zeroForOne);
        bytes memory data = abi.encode(address(tokenIn));
        // casting is safe because will only use tokens with supply well below 2**256
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 a0, int256 a1) = pool.swap(address(this), zeroForOne, -int256(amountOutRequested), limit, data);
        // casting to 'uint256' is safe because uniswap return convention
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = zeroForOne ? uint256(a0) : uint256(a1);
        // casting to 'uint256' is safe because uniswap return convention
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = zeroForOne ? uint256(-a1) : uint256(-a0);
    }

    // forge-lint: disable-start(boolean-cst)

    /// @notice Resolve the `sqrtPriceLimitX96` and a go/skip flag for a swap selling `tokenIn` for `tokenOut` on
    /// `pool`, bounding price impact to `maxSlippageBps` away from a fair rate of `outPerInNum / outPerInDen`.
    /// @param pool The Uniswap V3 pool address for the `tokenIn`/`tokenOut` pair.
    /// @param tokenIn The token the swap sells.
    /// @param tokenOut The token the swap buys.
    /// @param outPerInNum Numerator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param outPerInDen Denominator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param maxSlippageBps Maximum slippage allowed in basis points.
    /// @return limit The Q64.96 price limit to pass to the pool.
    function swapLimit(
        IUniswapV3Pool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 outPerInNum,
        uint256 outPerInDen,
        uint256 maxSlippageBps
    ) external view returns (uint160 limit, bool ok) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);

        // Fair price as an exact token1/token0 fraction. Selling token0 makes token1/token0
        // the tokenOut/tokenIn rate (outPerIn); selling token1 makes it the reciprocal, so
        // the numerator and denominator swap.
        (uint256 numerator, uint256 denominator) = zeroForOne ? (outPerInNum, outPerInDen) : (outPerInDen, outPerInNum);

        // Discount the price toward the side the swap moves it: a price-decreasing swap
        // allows down to price*(1-slip); a price-increasing swap up to price/(1-slip).
        if (zeroForOne) {
            numerator *= (BPS - maxSlippageBps);
            denominator *= BPS;
        } else {
            numerator *= BPS;
            denominator *= (BPS - maxSlippageBps);
        }

        // sqrtPriceX96 = sqrt(P) * 2**96 = sqrt(P * 2**192).
        uint256 raw = Math.sqrt(Math.mulDiv(numerator, ONE_X192, denominator));
        if (raw <= MIN_SQRT_RATIO || raw >= MAX_SQRT_RATIO) return (0, false);

        // The limit must sit on the side the price moves toward: below spot for a
        // price-decreasing swap, above spot for a price-increasing one. If the pool
        // is already past it, there is no room to trade within tolerance.
        // forge-lint: disable-next-line(unused-return)
        (uint160 spot,,,,,,) = pool.slot0();
        if (zeroForOne && raw >= spot) return (0, false);
        if (!zeroForOne && raw <= spot) return (0, false);

        // casting to 'uint160' is safe because MAX_SQRT_RATIO is uint160 and raw is smaller.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(raw), true);
    }

    function _setUnsetLimit(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (uint160 limit) {
        if (sqrtPriceLimitX96 != 0) {
            return sqrtPriceLimitX96;
        }
        if (zeroForOne) {
            return MIN_SQRT_RATIO + 1;
        } else {
            return MAX_SQRT_RATIO - 1;
        }
    }
}
