// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @title SwapLib
/// @notice Thin wrapper around FlowSwap V3's SwapRouter02 on Flow EVM mainnet.
///         Internal helpers — inlined into the caller, recipient is always
///         `address(this)`.
library SwapLib {
    ISwapRouter internal constant SWAP_ROUTER =
        ISwapRouter(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` with no slippage
    ///         bound. The router decides the realized price. Recipient is
    ///         always `address(this)`.
    /// @dev    Caller MUST have approved `SWAP_ROUTER` for `tokenIn`. Pool
    ///         `fee` is the FlowSwap V3 fee tier (e.g. 100 / 500 / 3000).
    ///         Setting `amountOutMinimum = 0` is intentional for legs whose
    ///         downstream accounting already enforces fairness (e.g. redeem
    ///         scales by realized output); use `swapExactInMin` for legs
    ///         that need an explicit floor.
    /// @param  tokenIn  Token being sold.
    /// @param  tokenOut Token being bought.
    /// @param  fee      Pool fee tier.
    /// @param  amountIn Amount of `tokenIn` to sell.
    /// @return amountOut Realized amount of `tokenOut` received.
    function swapExactIn(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
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

    /// @notice Same as `swapExactIn` but reverts in the router if the
    ///         realized output is below `amountOutMinimum`.
    /// @dev    Used by legs that need an explicit slippage cap derived from
    ///         an oracle price and a price-impact tolerance.
    /// @param  tokenIn          Token being sold.
    /// @param  tokenOut         Token being bought.
    /// @param  fee              Pool fee tier.
    /// @param  amountIn         Amount of `tokenIn` to sell.
    /// @param  amountOutMinimum Minimum acceptable `tokenOut` output; the
    ///                          router reverts if the realized amount is
    ///                          strictly less than this value.
    /// @return amountOut        Realized amount of `tokenOut` received.
    function swapExactInMin(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Best-effort partial swap: try to swap `amountIn` honoring an
    ///         `amountOutMinimum` floor; if the swap would breach the floor,
    ///         halve both the input and the floor and retry, up to `maxHalvings`
    ///         times. Returns the input actually swapped and the output received,
    ///         or `(0, 0)` if no size down to `amountIn >> maxHalvings` cleared
    ///         the floor.
    /// @dev    Used by vault-initiated rebalances so a swap too large to clear
    ///         the slippage floor still makes partial progress instead of
    ///         reverting the whole rebalance.
    ///
    ///         The floor is halved alongside the input because it derives from
    ///         an oracle-expected output that is linear in the input, whereas
    ///         realized AMM price impact grows with size. A smaller swap
    ///         therefore faces a proportionally-smaller floor *and* less price
    ///         impact, so it can clear a bound the full size could not. When the
    ///         shortfall is a uniform per-unit cost (a flat fee or an
    ///         oracle/pool spot divergence) rather than price impact, no size
    ///         clears the floor and the call returns `(0, 0)` — the caller
    ///         no-ops rather than trading at a bad price.
    ///
    ///         The retry wraps the router call in try/catch, so *any* revert
    ///         (slippage or otherwise) triggers a smaller retry; a pool that
    ///         fails at every attempted size yields `(0, 0)`. Caller MUST have
    ///         approved `SWAP_ROUTER` for `tokenIn`.
    /// @param  tokenIn          Token being sold.
    /// @param  tokenOut         Token being bought.
    /// @param  fee              Pool fee tier.
    /// @param  amountIn         Desired (full) amount of `tokenIn` to sell.
    /// @param  amountOutMinimum Slippage floor for the full `amountIn`; halved
    ///                          in lockstep with the input on each retry.
    /// @param  maxHalvings      Maximum number of halvings to attempt after the
    ///                          full-size attempt (smallest size is
    ///                          `amountIn >> maxHalvings`).
    /// @return amountInUsed     Input actually swapped (0 if none cleared).
    /// @return amountOut        Realized output received (0 if none cleared).
    function swapExactInPartial(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 maxHalvings
    ) internal returns (uint256 amountInUsed, uint256 amountOut) {
        for (uint256 i = 0; i <= maxHalvings; i++) {
            if (amountIn == 0) break;
            try SWAP_ROUTER.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            ) returns (
                uint256 out
            ) {
                return (amountIn, out);
            } catch {
                amountIn /= 2;
                amountOutMinimum /= 2;
            }
        }
        return (0, 0);
    }
}
