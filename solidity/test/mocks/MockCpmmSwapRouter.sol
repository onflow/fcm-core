// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Constant-product (x*y=k) swap mock that honors `sqrtPriceLimitX96` the
///      way a real Uniswap V3 pool does: it fills only up to the point where the
///      marginal price reaches the limit, then stops — a *partial fill* — and
///      consumes only the input it actually used, leaving the remainder with the
///      caller. This is what exercises the vault's price-limit-based partial
///      rebalancing; the flat `MockSwapRouter` cannot, since it has no price.
///
///      Reserves are virtual and static (set via `setReserves`, not updated
///      after a swap): the mock models a fixed-depth curve, which is all the
///      tests need (one committed swap per rebalance) and keeps fills exactly
///      reproducible. Pair both sides to the same value for a 1:1 spot price,
///      matching a 1e36 yield oracle and a `MockUniswapV3Pool` left at `Q96`.
///
///      Price convention matches the pool: `token0` is the lower-addressed
///      token, `P = reserve1 / reserve0`, `sqrtPriceX96 = sqrt(P) * 2**96`.
contract MockCpmmSwapRouter {
    uint256 internal constant Q96 = 1 << 96;

    /// @dev Virtual reserve per token, keyed by token address.
    mapping(address => uint256) public reserveOf;

    function setReserves(address token, uint256 reserve) external {
        reserveOf[token] = reserve;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(p.amountOutMinimum == 0, "amountOutMinimum not implemented in this mock")

        bool zeroForOne = p.tokenIn < p.tokenOut;
        (address token0, address token1) =
            zeroForOne ? (p.tokenIn, p.tokenOut) : (p.tokenOut, p.tokenIn);
        uint256 r0 = reserveOf[token0];
        uint256 r1 = reserveOf[token1];
        require(r0 > 0 && r1 > 0, "reserves unset");
        uint256 k = r0 * r1;
        uint256 rootK = Math.sqrt(k);

        // Cap the consumed input at the amount that moves the marginal price to
        // sqrtPriceLimitX96 (0 = no limit). Selling token0 grows r0 and lowers
        // the price; selling token1 grows r1 and raises it.
        uint256 consumed = p.amountIn;
        if (p.sqrtPriceLimitX96 != 0) {
            uint256 reserveInLimit = zeroForOne
                ? Math.mulDiv(rootK, Q96, p.sqrtPriceLimitX96)  // r0 at the lower price bound
                : Math.mulDiv(rootK, p.sqrtPriceLimitX96, Q96); // r1 at the upper price bound
            uint256 reserveIn = zeroForOne ? r0 : r1;
            uint256 maxConsumed = reserveInLimit > reserveIn ? reserveInLimit - reserveIn : 0;
            if (consumed > maxConsumed) consumed = maxConsumed;
        }
        if (consumed == 0) return 0;

        // out = reserveOut - k / (reserveIn + consumed)
        amountOut = zeroForOne
            ? r1 - Math.mulDiv(r0, r1, r0 + consumed)
            : r0 - Math.mulDiv(r0, r1, r1 + consumed);

        MockERC20(p.tokenIn).burn(msg.sender, consumed);
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
