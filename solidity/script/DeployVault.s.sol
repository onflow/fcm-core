// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/Script.sol";

import {FCMVault} from "../src/FCMVault.sol";
import {YieldTokenOracle} from "../src/YieldTokenOracle.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {ConfiguredScript} from "./ConfiguredScript.s.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title DeployVault
/// @notice Deploys the FCMVault (and, if the config has no `yieldOracle`
///         yet, a YieldTokenOracle reading the yield token's ERC4626
///         exchange rate) and performs initial admin setup. The broadcaster
///         becomes the vault admin/owner.
///
///         Pre-flight checks abort the run -- and therefore every broadcast
///         -- if the Morpho market is missing or unseeded, or the FlowSwap
///         pools don't match the config.
///
///         Required env:
///           MAX_TVL                initial TVL limit, asset base units
///                                  (deposits stay disabled at 0)
///         Optional env:
///           VAULT_NAME / VAULT_SYMBOL
///           EARLY_ACCESS_GRANTEES  comma-separated addresses to allowlist
///                                  in addition to the deployer
///
///         Usage (dry-run first by dropping --broadcast):
///           MAX_TVL=... forge script script/DeployVault.s.sol \
///             --rpc-url flow_mainnet --broadcast --account "$ACCOUNT"
contract DeployVault is ConfiguredScript {
    function run() public {
        Config memory c = _loadConfig();
        Market memory m = _requireMarketExists(c);
        require(m.totalSupplyAssets > 0, "market has no loan liquidity; run SeedMarket first");
        _requirePoolsExist(c);

        uint256 maxTvl = vm.envOr("MAX_TVL", uint256(0));
        string memory name = vm.envOr("VAULT_NAME", string("Flow Credit Markets WETH"));
        string memory symbol = vm.envOr("VAULT_SYMBOL", string("fcmWETH"));
        address[] memory grantees = vm.envOr("EARLY_ACCESS_GRANTEES", ",", new address[](0));

        vm.startBroadcast();
        address deployer = _broadcaster();

        address yieldOracle = c.yieldOracle;
        if (yieldOracle == address(0)) {
            // 1e36 spreads the vault's convertToAssets floor over 1e18 whole
            // shares, so the per-share rounding error is ~1e-18 relative and
            // stays negligible for any realistic position size.
            yieldOracle = address(new YieldTokenOracle(IERC4626(c.yieldToken), c.loanToken, 1e36));
        }
        uint256 p = YieldTokenOracle(yieldOracle).price();
        require(p > 0, "yield oracle reports zero price");
        console.log("yield oracle deployed at %s, NAV price %s", yieldOracle, p);

        FCMVault vault = new FCMVault(
            IFCMVault.InitParams({
                collateral: IERC20(c.collateral),
                loanToken: IERC20(c.loanToken),
                yieldToken: IERC20(c.yieldToken),
                marketOracle: c.marketOracle,
                marketIrm: c.marketIrm,
                marketLltv: c.marketLltv,
                feeYieldDebt: c.feeYieldDebt,
                feeAssetDebt: c.feeAssetDebt,
                yieldDebtPool: c.yieldDebtPool,
                assetDebtPool: c.assetDebtPool,
                healthFactorMin: c.healthFactorMin,
                healthFactorMax: c.healthFactorMax,
                healthFactorMinTarget: c.healthFactorMinTarget,
                healthFactorMaxTarget: c.healthFactorMaxTarget,
                yieldFactorMax: c.yieldFactorMax,
                yieldOracle: IOracle(yieldOracle),
                owner: deployer,
                maxSlippageBps: 100,
                recoveryDelay: c.recoveryDelay,
                name: name,
                symbol: symbol
            })
        );

        vault.grantEarlyAccess(deployer);
        for (uint256 i = 0; i < grantees.length; i++) {
            vault.grantEarlyAccess(grantees[i]);
        }
        vault.setMaxTvl(maxTvl);
        vm.stopBroadcast();

        console.log("=== deployment complete ===");
        console.log("FCMVault:     %s", address(vault));
        console.log("yield oracle: %s", yieldOracle);
        console.log("admin/owner:  %s", deployer);
        console.log("max TVL:      %s", maxTvl);
        console.log("market id:");
        console.logBytes32(Id.unwrap(_marketId(c)));
        console.log("Record the FCMVault and yield oracle addresses in the README.");
    }
}
