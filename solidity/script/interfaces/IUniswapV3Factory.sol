// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @dev Minimal factory interface (FlowSwap V3 is a Uniswap V3 fork).
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}
