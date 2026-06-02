// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @title SwapLib
/// @notice Thin wrapper around FlowSwap V3's SwapRouter02 on Flow EVM mainnet.
///         Internal helpers — inlined into the caller, recipient is always
///         `address(this)`.
library SwapLib {
    ISwapRouter internal constant SWAP_ROUTER = ISwapRouter(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);

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
    /// @dev    Used by rebalance legs that need an explicit slippage cap
    ///         derived from an oracle price and `maxPriceImpactBps`.
    /// @param  tokenIn          Token being sold.
    /// @param  tokenOut         Token being bought.
    /// @param  fee              Pool fee tier.
    /// @param  amountIn         Amount of `tokenIn` to sell.
    /// @param  amountOutMinimum Minimum acceptable `tokenOut` output; the
    ///                          router reverts if the realized amount is
    ///                          strictly less than this value.
    /// @return amountOut        Realized amount of `tokenOut` received.
    function swapExactInMin(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum)
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
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
