// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/Script.sol";

import {YieldTokenOracle} from "../src/YieldTokenOracle.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {ConfiguredScript, IUniswapV3Factory} from "./ConfiguredScript.s.sol";

/// @title Status
/// @notice Read-only report on everything a deployment depends on: the
///         Morpho market, the FlowSwap pools, oracle prices, and (optionally)
///         a deployer account's balances. Never broadcasts.
///
///         Usage:
///           forge script script/Status.s.sol --rpc-url flow_mainnet
///           DEPLOYER=0x... forge script script/Status.s.sol --rpc-url flow_mainnet
contract Status is ConfiguredScript {
    function run() public {
        Config memory c = _loadConfig();
        console.log("=== FCM deployment status (chain id %s) ===", block.chainid);

        _reportMarket(c);
        _reportPools(c);
        _reportOracles(c);
        _reportDeployer(c);
    }

    function _reportMarket(Config memory c) internal view {
        console.log("--- Morpho market");
        console.log("market id:");
        console.logBytes32(Id.unwrap(_marketId(c)));
        Market memory m = MarketLib.MORPHO.market(_marketId(c));
        if (m.lastUpdate == 0) {
            console.log("MARKET DOES NOT EXIST for config params -- fix config before deploying");
            return;
        }
        console.log("exists; last update at %s", m.lastUpdate);
        console.log("supplied loan token (borrowable): %s", m.totalSupplyAssets);
        console.log("borrowed loan token:              %s", m.totalBorrowAssets);
        if (m.totalSupplyAssets == 0) {
            console.log("NO SUPPLY LIQUIDITY -- run SeedMarket.s.sol before deploying the vault");
        }
    }

    function _reportPools(Config memory c) internal view {
        console.log("--- FlowSwap pools");
        address yieldPool = IUniswapV3Factory(c.swapFactory).getPool(c.yieldToken, c.loanToken, c.feeYieldDebt);
        address assetPool = IUniswapV3Factory(c.swapFactory).getPool(c.collateral, c.loanToken, c.feeAssetDebt);
        console.log("yield/debt pool (fee %s): %s", c.feeYieldDebt, yieldPool);
        console.log("asset/debt pool (fee %s): %s", c.feeAssetDebt, assetPool);
        if (yieldPool != c.yieldDebtPool) {
            console.log("CONFIG MISMATCH: yieldDebtPool in config is %s", c.yieldDebtPool);
        }
        if (yieldPool != address(0)) {
            (, int24 tick,,,,,) = IUniswapV3Pool(yieldPool).slot0();
            console.log("yield/debt spot tick: %s", vm.toString(tick));
            console.log("in-range liquidity: %s", IUniswapV3Pool(yieldPool).liquidity());
        }
    }

    function _reportOracles(Config memory c) internal {
        console.log("--- Oracles");
        try IOracle(c.marketOracle).price() returns (uint256 marketPrice) {
            console.log("market oracle price (1e36-scaled): %s", marketPrice);
        } catch {
            console.log("MARKET ORACLE REVERTING (stale Pyth feed?) -- vault operations will fail until it updates");
        }
        if (c.yieldOracle != address(0)) {
            console.log("yield oracle (configured): %s", c.yieldOracle);
            console.log("yield oracle price: %s", IOracle(c.yieldOracle).price());
        } else {
            // Not yet deployed: simulate one to preview the NAV price it
            // would report. This never broadcasts (Status has no broadcast
            // section).
            uint256 p = new YieldTokenOracle(IERC4626(c.yieldToken), c.loanToken).price();
            console.log("yield oracle not deployed; simulated NAV price: %s", p);
        }
    }

    function _reportDeployer(Config memory c) internal view {
        address deployer = vm.envOr("DEPLOYER", address(0));
        if (deployer == address(0)) return;
        console.log("--- Deployer %s", deployer);
        console.log("native FLOW (gas): %s", deployer.balance);
        console.log("collateral balance: %s", IERC20(c.collateral).balanceOf(deployer));
        console.log("loan token balance: %s", IERC20(c.loanToken).balanceOf(deployer));
    }
}
