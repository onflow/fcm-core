// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Constant-rate swap mock. `feeBps` (basis points) is taken off the
///      output amount; default 0 means lossless 1:1. Ignores fee tier and
///      price-limit fields entirely.
contract MockSwapRouter {
    uint256 public feeBps;

    function setFeeBps(uint256 newFeeBps) external {
        require(newFeeBps <= 10_000, "fee > 100%");
        feeBps = newFeeBps;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        MockERC20(p.tokenIn).burn(msg.sender, p.amountIn);
        amountOut = p.amountIn * (10_000 - feeBps) / 10_000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }

    /// @dev Exact-output mirror of `exactInputSingle`: grosses the input up by the
    ///      fee to deliver exactly `amountOut`, reverting if it exceeds
    ///      `amountInMaximum`. Ignores fee tier and price-limit fields.
    function exactOutputSingle(ISwapRouter.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        uint256 denom = 10_000 - feeBps;
        amountIn = (p.amountOut * 10_000 + denom - 1) / denom;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        MockERC20(p.tokenIn).burn(msg.sender, amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, p.amountOut);
    }
}
