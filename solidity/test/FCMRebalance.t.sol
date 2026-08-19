// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract FCMRebalanceTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    using Math for uint256;
    bytes errorEmergencyRecoveryActive = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);

    function setUp() public {
        deployVault();
    }

    function test_RevertOnRecovered() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.expectRevert(errorEmergencyRecoveryActive);
        vault.rebalance();
    }

    function test_NoLeverUpDuringRecovery() public {
        vault.depositFor(alice, 1 ether);
        marketOracle.setPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        uint256 hfBefore = vault.healthFactor();
        assertGt(hfBefore, HEALTH_FACTOR_MAX, "health factor should be above max");
        vault.rebalance();
        assertEq(vault.healthFactor(), hfBefore, "health factor should be unchanged");
    }

    function test_LeverDownDuringRecovery() public {
        vault.depositFor(alice, 1 ether);
        marketOracle.setPrice(1000e36);
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN, "health factor should be below min");
        vault.rebalance();
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MIN, "health factor should be increased");
    }
}
