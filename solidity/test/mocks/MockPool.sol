// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Single-pool swap mock with two modes. Flat (default): `exactInputSingle` converts
/// at a per-pair rate set via `setPrice` using `mulDiv` with the full 1e36-scale oracle
/// price — no truncation to 1e18, so extreme price ratios maintain full precision. At
/// least as precise as Uniswap V3 (same `FullMath.mulDiv` internally). Ignores
/// `sqrtPriceLimitX96` in flat mode. Price-impact (opt-in via `enablePriceImpact`): a
/// constant-product (x*y=k) curve using `setReserves` that honors `sqrtPriceLimitX96` like
/// a real Uniswap V3 pool, partial-filling up to the limit and consuming only the input
/// used. Implements `slot0()` and `fee()` so `SwapLib.swapLimit` and the vault
/// constructor's `IUniswapV3Pool(p).fee()` work identically to a real pool.
contract MockPool is IUniswapV3Pool {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev Virtual reserve per token, keyed by token address; only consulted in price-impact mode.
    mapping(address => uint256) public reserveOf;

    /// @dev Flat rate (tokenOut per tokenIn, 1e36-scaled) keyed by keccak256(tokenIn, tokenOut).
    /// Only consulted in flat mode. 0 = worthless (or unset); 1e36 = 1:1. Stored at full
    /// 1e36 precision so sub-1e18 oracle prices don't truncate to zero.
    mapping(bytes32 => uint256) internal flatPrice;

    /// @dev When true, `exactInputSingle` runs the constant-product curve and honors
    /// `sqrtPriceLimitX96`; off by default so swaps are flat / lossless.
    bool public priceImpactEnabled;

    /// @dev Sqrt price for `slot0()`, derived from the last `setPrice` call.
    uint160 public sqrtPriceX96;

    function setReserves(IERC20 token, uint256 reserve) external {
        reserveOf[address(token)] = reserve;
    }

    /// @dev Sets the rate for `tokenIn -> tokenOut` in the Morpho IOracle convention:
    /// `oraclePrice` is 1e36-scaled (1e36 = 1:1, 0 = worthless). Stored at full 1e36
    /// precision. The inverse direction must be set separately. `sqrtPriceX96` is derived
    /// so `slot0()` matches what `SwapLib.swapLimit` derives from the oracle.
    function setPrice(IERC20 tokenIn, IERC20 tokenOut, uint256 oraclePrice) external {
        flatPrice[_pairKey(address(tokenIn), address(tokenOut))] = oraclePrice;
        if (oraclePrice == 0) {
            sqrtPriceX96 = 0;
        } else if (address(tokenIn) < address(tokenOut)) {
            sqrtPriceX96 = uint160(Math.mulDiv(Math.sqrt(oraclePrice), Q96, 1e18));
        } else {
            sqrtPriceX96 = uint160(Math.mulDiv(1e18, Q96, Math.sqrt(oraclePrice)));
        }
    }

    /// @inheritdoc IUniswapV3Pool
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true);
    }

    /// @inheritdoc IUniswapV3Pool
    function fee() external pure returns (uint24) {
        return 0;
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
            // Flat: mulDiv with the full 1e36-scale price — no truncation, so extreme
            // ratios (e.g. 1e16) preserve full precision. A 0 rate yields amountOut 0.
            uint256 price = _resolvePrice(p.tokenIn, p.tokenOut);
            if (price == 0) return 0;
            amountOut = Math.mulDiv(p.amountIn, price, ORACLE_PRICE_SCALE);
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

        // Flat: mulDiv with the full 1e36-scale price — no truncation.
        uint256 price = _resolvePrice(p.tokenOut, p.tokenIn);
        require(price != 0, "zero price");
        amountIn = Math.mulDiv(p.amountOut, price, ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
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
