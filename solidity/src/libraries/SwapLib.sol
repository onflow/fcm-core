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
    ///         scales by realized output); use `swapExactInToLimit` for legs
    ///         that need an explicit price-impact bound.
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

    /// @notice Swap up to `amountIn` of `tokenIn` for `tokenOut`, stopping early
    ///         if the pool's marginal price reaches `sqrtPriceLimitX96`. The
    ///         pool fills the swap natively up to that price bound and then
    ///         stops without reverting, so a swap too large to complete within
    ///         the bound is a *partial fill* rather than a revert.
    /// @dev    This is the canonical Uniswap V3 mechanism for a best-effort
    ///         swap under a price bound: the pool's swap loop runs while input
    ///         remains AND the marginal price has not reached the limit, so the
    ///         marginal (and therefore average) execution price never crosses
    ///         the limit. `amountOutMinimum` is left at 0 — protection comes
    ///         entirely from the price limit, and a non-zero minimum would
    ///         revert a legitimate partial fill.
    ///
    ///         IMPORTANT: on a partial fill the router consumes LESS than
    ///         `amountIn` and leaves the unspent `tokenIn` with the caller — the
    ///         caller must account for the remainder (the vault repays it).
    ///         `sqrtPriceLimitX96` MUST be on the correct side of the current
    ///         pool price (below it for a 0->1 swap, above it for 1->0),
    ///         otherwise the pool reverts `SPL`; callers check the live price
    ///         first. Caller MUST have approved `SWAP_ROUTER` for `tokenIn`.
    /// @param  tokenIn           Token being sold.
    /// @param  tokenOut          Token being bought.
    /// @param  fee               Pool fee tier.
    /// @param  amountIn          Maximum amount of `tokenIn` to sell.
    /// @param  sqrtPriceLimitX96 Q64.96 marginal-price bound the swap will not
    ///                           cross; the fill stops here if reached.
    /// @return amountOut         Realized amount of `tokenOut` received.
    function swapExactInToLimit(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 amountOut) {
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
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
}
