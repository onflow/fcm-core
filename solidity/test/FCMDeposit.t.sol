// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMDepositTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    bytes errorActive = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);

    function setUp() public {
        deployVault();
    }

    function test_DepositBlockedDuringEmergencyRecovery() public {
        vm.startPrank(owner);
        vault.grantEarlyAccess(alice);
        vault.setMaxTvl(1 ether);
        vault.scheduleEmergencyRecovery();
        vm.stopPrank();

        vm.startPrank(alice);
        COLLATERAL_TOKEN.mint(alice, 10 ether);
        COLLATERAL_TOKEN.approve(address(vault), 10 ether);
        vm.expectRevert(errorActive);
        vault.deposit(1 ether, alice);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.cancelEmergencyRecovery();
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_DepositBlockedAfterEmergencyRecovery() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(errorActive);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }
}
