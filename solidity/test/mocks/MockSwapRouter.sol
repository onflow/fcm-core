// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Constant-rate swap mock. `feeBps` (basis points) is taken off the
///      output amount; default 0 means lossless 1:1. Ignores the price-limit
///      field. A per-fee-tier override (`setFeeBpsForPool`) lets a test haircut
///      one pool without touching the others. Reverts on a zero input amount,
///      like UniswapV3Pool's `require(amountSpecified != 0, 'AS')`.
contract MockSwapRouter {
    uint256 public feeBps;

    mapping(uint24 => uint256) internal poolFeeBps;
    mapping(uint24 => bool) internal poolFeeSet;

    function setFeeBps(uint256 newFeeBps) external {
        require(newFeeBps <= 10_000, "fee > 100%");
        feeBps = newFeeBps;
    }

    /// @dev Override the fee for a single pool (by fee tier); overrides the
    ///      global `feeBps` for swaps routed through that tier only.
    function setFeeBpsForPool(uint24 fee, uint256 newFeeBps) external {
        require(newFeeBps <= 10_000, "fee > 100%");
        poolFeeBps[fee] = newFeeBps;
        poolFeeSet[fee] = true;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(p.amountIn != 0, "AS");
        uint256 bps = poolFeeSet[p.fee] ? poolFeeBps[p.fee] : feeBps;
        MockERC20(p.tokenIn).burn(msg.sender, p.amountIn);
        amountOut = p.amountIn * (10_000 - bps) / 10_000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
