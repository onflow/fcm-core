// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @title SwapLib
/// @notice Thin wrapper around FlowSwap V3's SwapRouter02 on Flow EVM mainnet.
///         Internal helpers — inlined into the caller, recipient is always
///         `address(this)`.
library SwapLib {
    ISwapRouter internal constant SWAP_ROUTER = ISwapRouter(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);

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
}
