// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPool} from "./MockPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Trivial router mock: routes `exactInputSingle`/`exactOutputSingle` to the `MockPool` registered for the swap's
/// fee tier. Mirrors the real SwapRouter02, which pulls input from the caller then delegates to the pool. The router
/// holds no swap state — each pool owns its price, `slot0`, and swap logic.
contract MockSwapRouter {
    using SafeERC20 for MockERC20;
    mapping(uint24 => MockPool) internal poolForFee;

    function setPool(uint24 fee, MockPool pool) external {
        poolForFee[fee] = pool;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        // Pull input from the caller so the pool can burn it from us — the pool's `msg.sender` is this router, not
        // the vault.
        MockERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = poolForFee[p.fee].exactInputSingle(p);
        // Return any unconsumed input (price-impact mode may partial-fill).
        uint256 leftover = MockERC20(p.tokenIn).balanceOf(address(this));
        if (leftover > 0) MockERC20(p.tokenIn).safeTransfer(msg.sender, leftover);
    }

    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        // Pre-pull the max so the pool can burn from us; return the unused portion.
        MockERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountInMaximum);
        amountIn = poolForFee[p.fee].exactOutputSingle(p);
        uint256 leftover = MockERC20(p.tokenIn).balanceOf(address(this));
        if (leftover > 0) MockERC20(p.tokenIn).safeTransfer(msg.sender, leftover);
    }
}
