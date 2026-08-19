// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMHarvestTest is Test, Deployers {
    bytes errorEmergencyRecoveryActive = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);

    function setUp() public {
        deployVault();
    }

    function test_RevertOnEmergencyRecoveryActive() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();

        vm.expectRevert(errorEmergencyRecoveryActive);
        vault.harvest(type(uint256).max);
    }

    function test_RevertOnEmergencyRecoveryExecuted() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.expectRevert(errorEmergencyRecoveryActive);
        vault.harvest(type(uint256).max);
    }
}
