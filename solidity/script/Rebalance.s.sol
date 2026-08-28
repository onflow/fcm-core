// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title Rebalance
/// @notice Drives a LIVE FCMVault's leveraged Morpho position back inside its
///         configured LTV band, rebalancing to the re-entry target.
///         `rebalance` is permissionless, so any account with FLOW for gas can
///         run this.
///
///         The market oracle (Pyth) must be fresh — push an update with
///         `make mainnet-update-oracle` first, otherwise the oracle read
///         inside `rebalance` reverts with StalePrice.
///
///         Everything is read from the vault itself, so this works against any
///         FCMVault address with no config file. Spends real funds (swap fees
///         + price impact) when it actually rebalances, so dry-run first by
///         dropping --broadcast — the dry-run fork-simulates the exact same
///         sequence for free.
///
///         Env:
///           VAULT  (required) FCMVault address
///
///         Usage (dry-run first by dropping --broadcast):
///           VAULT=0x... forge script script/Rebalance.s.sol \
///             --rpc-url flow_mainnet --broadcast --account "$ACCOUNT"
contract Rebalance is Script {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using FCMHelpers for FCMVault;

    function run() public {
        FCMVault vault = FCMVault(vm.envAddress("VAULT"));

        uint256 ltvBefore = vault.ltv();
        uint256 debtBefore = vault.debt();

        vm.startBroadcast();
        vault.rebalance();
        vm.stopBroadcast();

        uint256 ltvAfter = vault.ltv();
        uint256 debtAfter = vault.debt();

        console.log("=== rebalance complete ===");
        console.log("vault:      %s", address(vault));
        console.log("LTV min:    %s", vault.LTV_MIN());
        console.log("LTV max:    %s", vault.LTV_MAX());
        console.log("LTV before:  %s", ltvBefore);
        console.log("LTV after:   %s", ltvAfter);
        console.log("debt before: %s", debtBefore);
        console.log("debt after:  %s", debtAfter);
        if (debtAfter == debtBefore) {
            console.log("no-op: LTV was inside [min, max]");
        }
    }
}
