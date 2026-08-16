// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @dev Minimal Uniswap-V3-style pool mock exposing only `slot0`, which the
///      vault reads for the pool's live marginal price (`sqrtPriceX96`) when
///      deriving a rebalance swap's `sqrtPriceLimitX96`. The price is settable
///      so tests can place the pool spot on either side of the oracle-derived
///      bound. `Q96` (2**96) is the 1:1 price for equal-decimal tokens.
contract MockUniswapV3Pool {
    uint160 public constant Q96 = 79_228_162_514_264_337_593_543_950_336; // 2**96

    uint160 internal sqrtPriceX96 = Q96; // default 1:1

    function setSqrtPriceX96(uint160 newSqrtPriceX96) external {
        sqrtPriceX96 = newSqrtPriceX96;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true);
    }
}
