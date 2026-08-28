// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {ForkDeployers} from "./ForkDeployers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract EmergencyRecoveryForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    address internal repayer = makeAddr("repayer");

    function setUp() public {
        setupFork();
        depositUsers(5, 1e8);
    }

    function test_emergencyRecoveryFork_externalRepay() public {
        assertGt(vault.debt(), 0);

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());

        uint256 borrowShares = vault.position().borrowShares;
        deal(address(PYUSD0), owner, vault.debt().mulDiv(101, 100));
        vm.startPrank(owner);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(_market(), 0, borrowShares, address(vault), "");
        vm.stopPrank();

        assertEq(vault.debt(), 0);
        assertEq(vault.ltv(), 0);

        uint256 expectedCollateralOut = WBTC.balanceOf(address(vault)) + vault.collateral();
        uint256 expectedYieldOut = FUSDEV.balanceOf(address(vault));
        assertGt(expectedCollateralOut, 0);
        assertGt(expectedYieldOut, 0);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IFCMVault.EmergencyRecoveryExecuted(expectedCollateralOut, expectedYieldOut, 0);
        vault.executeEmergencyRecovery();

        assertTrue(vault.emergencyRecovered());
        assertEq(WBTC.balanceOf(address(owner)), expectedCollateralOut);
        assertEq(FUSDEV.balanceOf(address(owner)), expectedYieldOut);
    }
}
