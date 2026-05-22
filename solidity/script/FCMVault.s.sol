// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {FCMVault} from "../src/FCMVault.sol";

contract FCMVaultScript is Script {
    FCMVault public vault;

    function run() public {
        vm.startBroadcast();

        vault = new FCMVault(vm.envAddress("MARKET_ORACLE"), vm.envAddress("YIELD_ORACLE"));

        console.log("FCMVault deployed to:", address(vault));

        vm.stopBroadcast();
    }
}
