// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BPS} from "../FCMVault.sol";
import {ISwapRouter02} from "../interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SwapLib
/// @author Flow Foundation
/// @notice Thin wrapper around FlowSwap V3's SwapRouter02 on Flow EVM mainnet. Internal helpers — inlined into the
/// caller, recipient is always `address(this)`.
library SwapLib {
    /// @custom:security non-reentrant
    ISwapRouter02 internal constant SWAP_ROUTER = ISwapRouter02(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);
    /// @dev Uniswap V3 tick-math bounds on a valid `sqrtPriceLimitX96`. A limit outside `(MIN_SQRT_RATIO,
    /// MAX_SQRT_RATIO)` is rejected by the pool; the vault treats such a limit as "no feasible swap" and skips.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev Q64.96 fixed-point one squared (`2**192`), used to build the `sqrtPriceX96` price limit for rebalance
    /// swaps.
    uint256 internal constant ONE_X192 = 1 << 192;

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` with no slippage bound. The router decides the realized
    /// price. Recipient is always `address(this)`.
    /// @dev Caller MUST have approved `SWAP_ROUTER` for `tokenIn`. Pool
    /// `fee` is the FlowSwap V3 fee tier (e.g. 100 / 500 / 3000). Setting `amountOutMinimum = 0` is intentional for
    /// legs whose downstream accounting already enforces fairness (e.g. redeem scales by realized output); use
    /// `swapExactInToLimit` for legs that need an explicit price-impact bound.
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being bought.
    /// @param fee Pool fee tier.
    /// @param amountIn Amount of `tokenIn` to sell.
    /// @return amountOut Realized amount of `tokenOut` received.
    function swapExactIn(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Swap up to `amountIn` of `tokenIn` for `tokenOut`, stopping early if the pool's marginal price reaches
    /// `sqrtPriceLimitX96`. The pool fills the swap natively up to that price bound and then stops without reverting,
    /// so a swap too large to complete within the bound is a *partial fill* rather than a revert.
    /// @dev This is the
    /// canonical Uniswap V3 mechanism for a best-effort swap under a price bound: the pool's swap loop runs while input
    /// remains AND the marginal price has not reached the limit, so the marginal (and therefore average) execution
    /// price never crosses the limit. `amountOutMinimum` is left at 0 — protection comes entirely from the price
    /// limit, and a non-zero minimum would revert a legitimate partial fill.
    ///
    ///         IMPORTANT: on a partial fill the router consumes LESS than `amountIn` and leaves the unspent `tokenIn`
    /// with the caller — the caller must account for the remainder (the vault repays it). `sqrtPriceLimitX96` MUST be
    /// on the correct side of the current pool price (below it for a 0->1 swap, above it for 1->0), otherwise the pool
    /// reverts `SPL`; callers check the live price first. Caller MUST have approved `SWAP_ROUTER` for `tokenIn`.
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being bought.
    /// @param fee Pool fee tier.
    /// @param amountIn Maximum amount of `tokenIn` to sell.
    /// @param sqrtPriceLimitX96 Q64.96 marginal-price bound the swap will not cross; the fill stops here if reached.
    /// @return amountOut Realized amount of `tokenOut` received.
    function swapExactInToLimit(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountOut) {
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
    }

    /// @notice Swap `tokenIn` for exactly `amountOut` of `tokenOut`, reverting in the router if it would cost more than
    /// `amountInMaximum`.
    /// @dev Exact-output single-hop; recipient is always `address(this)`. Used by redeem's Case-B
    /// path to buy exactly the redeemer's debt shortfall from their collateral, spending no more than the
    /// slippage-grossed collateral withdrawn for it.
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being bought.
    /// @param fee Pool fee tier.
    /// @param amountOut Exact amount of `tokenOut` to receive.
    /// @param amountInMaximum Max `tokenIn` to spend; router reverts above it.
    /// @return amountIn Realized `tokenIn` spent.
    function swapExactOut(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut, uint256 amountInMaximum)
        internal
        returns (uint256 amountIn)
    {
        return SWAP_ROUTER.exactOutputSingle(
            ISwapRouter02.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Resolve the `sqrtPriceLimitX96` and a go/skip flag for a swap selling `tokenIn` for `tokenOut` on
    /// `pool`, bounding price impact to `maxSlippageBps` away from a fair rate of `outPerInNum / outPerInDen`
    /// (`tokenOut` per `tokenIn`, with token decimals already baked into the fraction). Pure Uniswap-price math: it
    /// does not know or care which token is the loan/oracle side.
    /// @dev The pool price is `token1/token0` (token0 = the
    /// lower-address token). The fair rate is mapped to that coordinate and discounted toward the side the swap moves
    /// it: selling token0 (`zeroForOne`) drives the price down (limit below spot), selling token1 drives it up (limit
    /// above spot). The pool then fills only while its marginal price is on the good side of the limit, so the realized
    /// average price is bounded by `maxSlippageBps` of price impact relative to the fair rate.
    ///
    /// `ok` is false when the limit is out of tick-math range, or when the pool's live marginal price is already on the
    /// bad side of it (any swap would no-op or revert `SPL`) — the caller then skips.
    /// @param pool The Uniswap V3 pool address for the `tokenIn`/`tokenOut` pair.
    /// @param tokenIn The token the swap sells.
    /// @param tokenOut The token the swap buys.
    /// @param outPerInNum Numerator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param outPerInDen Denominator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param maxSlippageBps Maximum slippage allowed in basis points.
    /// @return limit The Q64.96 price limit to pass to the pool.
    /// @return ok Whether a swap should be attempted.
    function swapLimit(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 outPerInNum,
        uint256 outPerInDen,
        uint256 maxSlippageBps
    ) external view returns (uint160 limit, bool ok) {
        // Uniswap orders the pair by address: token0 is the lower-address token
        // and the pool price is token1/token0. Selling token0 (`zeroForOne`) pushes
        // the price down; selling token1 pushes it up.
        bool zeroForOne = tokenIn < tokenOut;

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
        // slither-disable-next-line unused-return -> only sqrtPriceX96 is read; the other slot0 fields are unused
        (uint160 spot,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (zeroForOne && raw >= spot) return (0, false);
        if (!zeroForOne && raw <= spot) return (0, false);

        // casting to 'uint160' is safe because MAX_SQRT_RATIO is uint160 and raw is smaller.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(raw), true);
    }
}
