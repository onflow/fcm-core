// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IUniswapV3Pool
/// @notice Minimal subset of the Uniswap V3 pool interface used by the
///         deployment scripts to report pool state. FlowSwap V3 is a
///         Uniswap V3 fork, so its pools expose the same ABI.
interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}
