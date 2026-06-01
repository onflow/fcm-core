// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCMVault} from "../src/FCMVault.sol";

contract FCMVaultScript is Script {
    FCMVault public vault;

    function run() public {
        vm.startBroadcast();

        IERC20 asset = IERC20(vm.envAddress("ASSET"));
        address admin = vm.envAddress("ADMIN");
        vault = new FCMVault("Flow Credit Markets Vault", "fcmV", asset, admin);

        console.log("FCMVault deployed to:", address(vault));

        vm.stopBroadcast();
    }
}
