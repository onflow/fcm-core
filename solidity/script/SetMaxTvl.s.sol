// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";

import {FCMVault} from "../src/FCMVault.sol";
import {ConfiguredScript} from "./ConfiguredScript.s.sol";

/// @title SetMaxTvl
/// @notice Updates a deployed FCMVault's TVL limit. Deposits stay disabled
///         while the limit is 0; raising it opens (or expands) capacity, and
///         the limit applies only to new deposits. The broadcaster must be the
///         vault owner.
///
///         Required env:
///           VAULT    address of the deployed FCMVault
///           MAX_TVL  new TVL limit, asset (WETH) base units
///
///         Usage (dry-run first by dropping --broadcast):
///           VAULT=0x... MAX_TVL=... forge script script/SetMaxTvl.s.sol \
///             --rpc-url flow_mainnet --broadcast --account "$ACCOUNT"
contract SetMaxTvl is ConfiguredScript {
    function run() public {
        FCMVault vault = FCMVault(vm.envAddress("VAULT"));
        uint256 newMaxTvl = vm.envUint("MAX_TVL");

        vm.startBroadcast();
        address sender = _broadcaster();
        require(sender == vault.owner(), "broadcaster is not the vault owner");

        uint256 previous = vault.maxTvl();
        vault.setMaxTvl(newMaxTvl);
        vm.stopBroadcast();

        console.log("vault %s", address(vault));
        console.log("maxTvl: %s -> %s (asset base units)", previous, newMaxTvl);
    }
}
