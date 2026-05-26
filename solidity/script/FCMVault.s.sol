// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCMVault} from "../src/FCMVault.sol";

contract FCMVaultScript is Script {
    FCMVault public vault;

    function run() public {
        vm.startBroadcast();

        vault = new FCMVault(FCMVault.InitParams({
            collateral:    IERC20(vm.envAddress("COLLATERAL")),
            loanToken:     IERC20(vm.envAddress("LOAN_TOKEN")),
            yieldToken:    IERC20(vm.envAddress("YIELD_TOKEN")),
            marketOracle:  vm.envAddress("MARKET_ORACLE"),
            marketIrm:     vm.envAddress("MARKET_IRM"),
            marketLltv:    vm.envUint("MARKET_LLTV"),
            feeYieldDebt:  uint24(vm.envUint("FEE_YIELD_DEBT")),
            hfUpperTarget: vm.envUint("HF_UPPER_TARGET"),
            yieldOracle:   vm.envAddress("YIELD_ORACLE"),
            name:          vm.envString("VAULT_NAME"),
            symbol:        vm.envString("VAULT_SYMBOL")
        }));

        console.log("FCMVault deployed to:", address(vault));

        vm.stopBroadcast();
    }
}
