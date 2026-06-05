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
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
