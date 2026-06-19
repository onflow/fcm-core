// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";

import {FCMVault} from "../src/FCMVault.sol";
import {ConfiguredScript} from "./ConfiguredScript.s.sol";

/// @title GrantEarlyAccess
/// @notice Allow-lists additional accounts on a deployed FCMVault by granting
///         them EARLY_ACCESS_ROLE -- the role required to deposit, hold, or
///         receive vault shares. The broadcaster must hold the role's admin
///         (DEFAULT_ADMIN_ROLE, held by the deployer). Addresses already on
///         the allow-list are skipped, so the script is safe to re-run.
///
///         Required env:
///           VAULT                  address of the deployed FCMVault
///           EARLY_ACCESS_GRANTEES  comma-separated addresses to allow-list
///
///         Usage (dry-run first by dropping --broadcast):
///           VAULT=0x... EARLY_ACCESS_GRANTEES=0xabc...,0xdef... \
///           forge script script/GrantEarlyAccess.s.sol --rpc-url flow_mainnet \
///             --broadcast --account "$ACCOUNT"
contract GrantEarlyAccess is ConfiguredScript {
    function run() public {
        FCMVault vault = FCMVault(vm.envAddress("VAULT"));
        address[] memory grantees = vm.envAddress("EARLY_ACCESS_GRANTEES", ",");
        require(grantees.length > 0, "no grantees in EARLY_ACCESS_GRANTEES");

        bytes32 role = vault.EARLY_ACCESS_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vm.startBroadcast();
        address sender = _broadcaster();
        require(vault.hasRole(adminRole, sender), "broadcaster lacks DEFAULT_ADMIN_ROLE");

        uint256 granted;
        for (uint256 i = 0; i < grantees.length; i++) {
            address grantee = grantees[i];
            if (vault.hasRole(role, grantee)) {
                console.log("already allow-listed, skipping: %s", grantee);
                continue;
            }
            vault.grantRole(role, grantee);
            granted++;
            console.log("allow-listed: %s", grantee);
        }
        vm.stopBroadcast();

        console.log("granted EARLY_ACCESS_ROLE to %s of %s address(es)", granted, grantees.length);
    }
}
