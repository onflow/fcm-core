// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Constant-product (x*y=k) swap mock used to exercise price-impact-
///      dependent slippage. Unlike `MockSwapRouter` — a flat per-unit rate no
///      trade size can escape — here a smaller trade gets a better average
///      price, so a swap that breaches a slippage floor at full size can clear
///      it at a reduced size. That is exactly the property partial rebalancing
///      relies on, so this mock is what the partial-progress tests etch over
///      the swap router.
///
///      Mechanics: `out = reserveOut * amountIn / (reserveIn + amountIn)`, the
///      standard constant-product fill. The marginal (spot) rate is
///      `reserveOut / reserveIn`; the realized average rate
///      `reserveOut / (reserveIn + amountIn)` degrades as `amountIn` grows, so
///      the slippage versus spot is `amountIn / (reserveIn + amountIn)`. With
///      equal reserves the spot rate is 1:1, matching a 1e36 yield oracle.
///
///      Reserves are virtual: like the flat mock it mints/burns tokens and does
///      NOT update reserves after a swap, so it models a fixed-depth curve
///      (price impact within a single swap, no inventory accounting). The
///      partial-rebalance tests only need one committed swap per rebalance, so
///      that is sufficient and keeps the expected output exactly computable.
contract MockCpmmSwapRouter {
    /// @dev Virtual reserve per token, keyed by token address.
    mapping(address => uint256) public reserveOf;

    /// @notice Set the virtual reserve for a token. Set both sides of a pair to
    ///         the same value for a 1:1 spot rate.
    function setReserves(address token, uint256 reserve) external {
        reserveOf[token] = reserve;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        uint256 reserveIn = reserveOf[p.tokenIn];
        uint256 reserveOut = reserveOf[p.tokenOut];
        require(reserveIn > 0 && reserveOut > 0, "reserves unset");

        amountOut = reserveOut * p.amountIn / (reserveIn + p.amountIn);
        require(amountOut >= p.amountOutMinimum, "Too little received");

        MockERC20(p.tokenIn).burn(msg.sender, p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
