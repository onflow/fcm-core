// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPool} from "./MockPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Trivial router mock: routes swaps to the `MockPool` registered for the token pair.
/// The real SwapRouter02 derives the pool from `tokenIn + tokenOut + fee`, but mock pools
/// all return 0 for `fee()`, so routing by fee would collide. Route by pair instead.
contract MockSwapRouter {
    using SafeERC20 for MockERC20;
    mapping(bytes32 => MockPool) internal poolForPair;

    function setPool(MockPool pool, address tokenA, address tokenB) external {
        poolForPair[_pairKey(tokenA, tokenB)] = pool;
        poolForPair[_pairKey(tokenB, tokenA)] = pool;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        MockERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = _pool(p.tokenIn, p.tokenOut).exactInputSingle(p);
        uint256 leftover = MockERC20(p.tokenIn).balanceOf(address(this));
        if (leftover > 0) MockERC20(p.tokenIn).safeTransfer(msg.sender, leftover);
    }

    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        MockERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountInMaximum);
        amountIn = _pool(p.tokenIn, p.tokenOut).exactOutputSingle(p);
        uint256 leftover = MockERC20(p.tokenIn).balanceOf(address(this));
        if (leftover > 0) MockERC20(p.tokenIn).safeTransfer(msg.sender, leftover);
    }

    function _pool(address tokenIn, address tokenOut) internal view returns (MockPool) {
        MockPool pool = poolForPair[_pairKey(tokenIn, tokenOut)];
        require(address(pool) != address(0), "no pool for pair");
        return pool;
    }

    function _pairKey(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}
