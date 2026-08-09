// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {console} from "forge-std/Script.sol";

// import {ISwapRouter} from "../src/interfaces/external/ISwapRouter.sol";
// import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
// import {SwapLib} from "../src/libraries/SwapLib.sol";
// import {ConfiguredScript, IUniswapV3Factory} from "./ConfiguredScript.s.sol";

// /// @dev Wrapped FLOW (canonical WETH9-style wrapper for native FLOW on Flow
// ///      EVM mainnet). `deposit` credits WFLOW to msg.sender 1:1.
// interface IWFLOW is IERC20 {
//     function deposit() external payable;
// }

// /// @dev FlowSwap V3 pool ordering check (the shared IUniswapV3Pool subset
// ///      doesn't expose token0). Used only to orient the spot-price math.
// interface IPoolTokens {
//     function token0() external view returns (address);
// }

// /// @title SwapForWeth
// /// @notice Acquires the vault's collateral asset (WETH) for the broadcaster by
// ///         wrapping native FLOW and swapping WFLOW -> WETH on the same FlowSwap
// ///         V3 pool the protocol trades against. Used to fund the deployer
// ///         before `LiveCheck.s.sol`.
// ///
// ///         Slippage is bounded by SLIPPAGE_BPS against the pool's current spot
// ///         price (NOT a manipulable on-chain quote of our own making — the
// ///         min-out is derived from slot0 and enforced by the router).
// ///
// ///         Usage (dry-run first by dropping --broadcast):
// ///           SWAP_AMOUNT=<FLOW wei to convert; default = half native balance> \
// ///           SLIPPAGE_BPS=<max slippage, default 300> \
// ///           forge script script/SwapForWeth.s.sol --rpc-url flow_mainnet \
// ///             --broadcast --account "$ACCOUNT"
// contract SwapForWeth is ConfiguredScript {
//     // Canonical Wrapped FLOW on Flow EVM mainnet.
//     IWFLOW internal constant WFLOW = IWFLOW(0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e);
//     // Fee tier of the WFLOW/WETH pool we route through (0.3%).
//     uint24 internal constant WFLOW_WETH_FEE = 3000;
//     uint256 internal constant Q96 = 0x1000000000000000000000000; // 2**96
//     uint256 internal constant BPS = 10_000;

//     function run() public {
//         Config memory c = _loadConfig();
//         address weth = c.collateral;

//         uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(300));
//         require(slippageBps < BPS, "SLIPPAGE_BPS must be < 10000");

//         address pool = IUniswapV3Factory(c.swapFactory).getPool(address(WFLOW), weth, WFLOW_WETH_FEE);
//         require(pool != address(0), "no WFLOW/WETH pool at fee tier");

//         vm.startBroadcast();
//         address account = _broadcaster();

//         // Default to converting half the native balance, leaving the rest for
//         // gas; override with SWAP_AMOUNT (FLOW base units / wei).
//         uint256 amountIn = vm.envOr("SWAP_AMOUNT", account.balance / 2);
//         require(amountIn > 0, "nothing to swap");
//         require(account.balance > amountIn, "SWAP_AMOUNT leaves no FLOW for gas");

//         uint256 minOut = _minOut(pool, weth, amountIn, slippageBps);

//         // 1. Wrap native FLOW -> WFLOW (credited to the broadcaster).
//         WFLOW.deposit{value: amountIn}();
//         // 2. Approve the router and swap WFLOW -> WETH back to the broadcaster.
//         WFLOW.approve(address(SwapLib.SWAP_ROUTER), amountIn);
//         uint256 received = SwapLib.SWAP_ROUTER
//             .exactInputSingle(
//                 ISwapRouter.ExactInputSingleParams({
//                     tokenIn: address(WFLOW),
//                     tokenOut: weth,
//                     fee: WFLOW_WETH_FEE,
//                     recipient: account,
//                     amountIn: amountIn,
//                     amountOutMinimum: minOut,
//                     sqrtPriceLimitX96: 0
//                 })
//             );
//         vm.stopBroadcast();

//         console.log("swapped %s WFLOW (wei) for %s WETH (wei)", amountIn, received);
//         console.log("min acceptable was %s; account now holds %s WETH (wei)", minOut,
// IERC20(weth).balanceOf(account)); }

//     /// @dev Spot-price-derived minimum WETH out for `amountIn` WFLOW, less
//     ///      `slippageBps`. WFLOW and WETH are both 18 decimals, so no decimal
//     ///      scaling is needed. sqrtPriceX96 encodes sqrt(token1/token0)*2^96.
//     function _minOut(address pool, address weth, uint256 amountIn, uint256 slippageBps)
//         internal
//         view
//         returns (uint256)
//     {
//         (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
//         uint256 sqrtP = uint256(sqrtPriceX96);

//         uint256 expectedOut;
//         if (IPoolTokens(pool).token0() == weth) {
//             // WETH = token0, WFLOW = token1. price(WFLOW per WETH) = (sqrtP/2^96)^2.
//             // out(WETH) = amountIn(WFLOW) * 2^192 / sqrtP^2.
//             expectedOut = Math.mulDiv(Math.mulDiv(amountIn, Q96, sqrtP), Q96, sqrtP);
//         } else {
//             // WFLOW = token0, WETH = token1. price(WETH per WFLOW) = (sqrtP/2^96)^2.
//             // out(WETH) = amountIn(WFLOW) * sqrtP^2 / 2^192.
//             expectedOut = Math.mulDiv(Math.mulDiv(amountIn, sqrtP, Q96), sqrtP, Q96);
//         }
//         return expectedOut * (BPS - slippageBps) / BPS;
//     }
// }
