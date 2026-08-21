// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Single-pool swap mock with two modes. Flat (default): `exactInputSingle` converts at a per-pair rate set via
/// `setPrice` and ignores `sqrtPriceLimitX96` — `amountOut = amountIn * price / 1e18` exactly, so exact-equality
/// asserts pass without slippage noise; this is what `Deployers` wires by default. Price-impact (opt-in via
/// `enablePriceImpact`): a constant-product (x*y=k) curve using `setReserves` that honors `sqrtPriceLimitX96` like a
/// real Uniswap V3 pool, partial-filling up to the limit and consuming only the input used — this is what exercises
/// the vault's price-limit-based partial rebalancing. Implements `slot0()` so `SwapLib.swapLimit` can read the marginal
/// price. Price convention: `setPrice` is WAD-scaled (1e18 = 1:1); `sqrtPriceX96 = sqrt(token1/token0) * Q96`.
contract MockPool {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant WAD = 1e18;

    /// @dev Virtual reserve per token, keyed by token address; only consulted in price-impact mode.
    mapping(address => uint256) public reserveOf;

    /// @dev Flat rate (tokenOut per tokenIn, WAD-scaled) keyed by keccak256(tokenIn, tokenOut); only consulted in flat
    /// mode. 0 = worthless (or unset); 1e18 = 1:1.
    mapping(bytes32 => uint256) internal flatPrice;

    /// @dev When true, `exactInputSingle` runs the constant-product curve and honors `sqrtPriceLimitX96`; off by
    /// default so swaps are flat / lossless.
    bool public priceImpactEnabled;

    /// @dev Sqrt price for `slot0()`, derived from the last `setPrice` call.
    uint160 public sqrtPriceX96;

    function setReserves(address token, uint256 reserve) external {
        reserveOf[token] = reserve;
    }

    /// @dev Sets the rate for `tokenIn -> tokenOut` in the Morpho IOracle convention: `oraclePrice` is 1e36-scaled
    /// (loan-per-tokenIn, 1e36 = 1:1, 0 = worthless). Internally converts to the WAD flat rate (`oraclePrice / 1e18`)
    /// and derives `sqrtPriceX96` so `slot0()` matches what `SwapLib.swapLimit` derives from the oracle. The inverse
    /// direction is auto-derived in `_resolvePrice` — only one direction needs setting.
    function setPrice(address tokenIn, address tokenOut, uint256 oraclePrice) external {
        flatPrice[_pairKey(tokenIn, tokenOut)] = oraclePrice / 1e18; // 1e36-scaled -> WAD-scaled
        // sqrtPriceX96 = sqrt(token1/token0) * Q96 (token0 = min, token1 = max). Each branch computes spot for its own
        // direction; the zeroForOne/oneForZero spots are reciprocals scaled by 1e36, so using one formula for both
        // leaves the pool off-oracle for the other. oraclePrice == 0 -> sqrtPriceX96 = 0, which SwapLib.swapLimit
        // rejects (raw <= MIN_SQRT_RATIO -> ok=false).
        if (oraclePrice == 0) {
            sqrtPriceX96 = 0;
        } else if (tokenIn < tokenOut) {
            sqrtPriceX96 = uint160(Math.mulDiv(Math.sqrt(oraclePrice), Q96, 1e18));
        } else {
            sqrtPriceX96 = uint160(Math.mulDiv(1e18, Q96, Math.sqrt(oraclePrice)));
        }
    }

    /// @dev Uniswap V3 `slot0()` — only `sqrtPriceX96` is read by `SwapLib.swapLimit`.
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true);
    }

    function enablePriceImpact() external {
        priceImpactEnabled = true;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(p.amountIn != 0, "AS");

        if (!priceImpactEnabled) {
            // Flat: ignores sqrtPriceLimitX96; a 0 rate (worthless or unset) yields amountOut 0.
            uint256 price = _resolvePrice(p.tokenIn, p.tokenOut);
            amountOut = p.amountIn * price / WAD;
            MockERC20(p.tokenIn).burn(msg.sender, p.amountIn);
            MockERC20(p.tokenOut).mint(p.recipient, amountOut);
            return amountOut;
        }

        // Price-impact mode: constant-product curve honoring sqrtPriceLimitX96.
        require(p.amountOutMinimum == 0, "amountOutMinimum not implemented in this mock");

        bool zeroForOne = p.tokenIn < p.tokenOut;
        (address token0, address token1) = zeroForOne ? (p.tokenIn, p.tokenOut) : (p.tokenOut, p.tokenIn);
        uint256 r0 = reserveOf[token0];
        uint256 r1 = reserveOf[token1];
        require(r0 > 0 && r1 > 0, "reserves unset");
        uint256 k = r0 * r1;
        uint256 rootK = Math.sqrt(k);

        uint256 consumed = p.amountIn;
        if (p.sqrtPriceLimitX96 != 0) {
            uint256 reserveInLimit = zeroForOne
                ? Math.mulDiv(rootK, Q96, p.sqrtPriceLimitX96)
                : Math.mulDiv(rootK, p.sqrtPriceLimitX96, Q96);
            uint256 reserveIn = zeroForOne ? r0 : r1;
            uint256 maxConsumed = reserveInLimit > reserveIn ? reserveInLimit - reserveIn : 0;
            if (consumed > maxConsumed) consumed = maxConsumed;
        }
        if (consumed == 0) return 0;

        amountOut = zeroForOne ? r1 - Math.mulDiv(r0, r1, r0 + consumed) : r0 - Math.mulDiv(r0, r1, r1 + consumed);

        MockERC20(p.tokenIn).burn(msg.sender, consumed);
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }

    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        require(p.amountOut != 0, "AS");
        require(!priceImpactEnabled, "exactOutputSingle not implemented in price-impact mode");
        uint256 price = _resolvePrice(p.tokenOut, p.tokenIn);
        amountIn = (p.amountOut * price + WAD - 1) / WAD;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        MockERC20(p.tokenIn).burn(msg.sender, amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, p.amountOut);
    }

    function _pairKey(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    function _resolvePrice(address tokenIn, address tokenOut) internal view returns (uint256) {
        return flatPrice[_pairKey(tokenIn, tokenOut)];
    }
}
