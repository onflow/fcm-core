// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract FCMEmergencyRecoveryTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    bytes errorBobUnauthorized = Errors.ownableUnauthorizedAccount(address(bob));
    bytes errorNotReady = Errors.emergencyRecoveryNotReady();
    bytes errorActive = Errors.emergencyRecoveryActive();

    function setUp() public {
        deployVault();

        vm.prank(owner);
        vault.setMaxTvl(1e21);
        grantFundApprove(alice, 1 ether);
    }

    function test_emergencyRecovery_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(errorBobUnauthorized);
        vault.scheduleEmergencyRecovery();
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();

        vm.prank(bob);
        vm.expectRevert(errorBobUnauthorized);
        vault.cancelEmergencyRecovery();
        vm.prank(owner);
        vault.cancelEmergencyRecovery();

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(block.timestamp + vault.EMERGENCY_RECOVERY_DELAY());
        vm.prank(bob);
        vm.expectRevert(errorBobUnauthorized);
        vault.executeEmergencyRecovery();
        vm.prank(owner);
        vault.executeEmergencyRecovery();
    }

    function test_emergencyRecovery_noScheduled() public {
        vm.prank(owner);
        vm.expectRevert(errorNotReady);
        vault.executeEmergencyRecovery();
    }

    function test_emergencyRecovery_recoveryDelay() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        uint256 snapshot = vm.snapshotState();

        assertEq(vault.emergencyRecoveryValidAt(), block.timestamp + vault.EMERGENCY_RECOVERY_DELAY());
        assertEq(vault.emergencyRecoveryActive(), true);
        vm.warp(vault.emergencyRecoveryValidAt() - 1);

        vm.expectRevert(errorNotReady);
        vault.executeEmergencyRecovery();

        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.revertToState(snapshot);
        vm.warp(vault.emergencyRecoveryValidAt() * 2);
        vault.executeEmergencyRecovery();
    }

    function test_emergencyRecovery_scheduleTwiceIsIdempotent() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vault.scheduleEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), block.timestamp + vault.EMERGENCY_RECOVERY_DELAY());
        assertEq(vault.emergencyRecoveryActive(), true);
    }

    function test_emergencyRecovery_cancelNotScheduled() public {
        vm.startPrank(owner);
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0);
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_emergencyRecovery_cancelTwiceIsIdempotent() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vault.cancelEmergencyRecovery();
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0);
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_emergencyRecovery_noCancelAfterExecute() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        uint64 emergencyRecoveryValidAt = vault.emergencyRecoveryValidAt();
        vm.warp(emergencyRecoveryValidAt);
        vault.executeEmergencyRecovery();
        assertEq(emergencyRecoveryValidAt, vault.emergencyRecoveryValidAt());
        vm.expectRevert(errorActive);
        vault.cancelEmergencyRecovery();
    }

    function test_emergencyRecovery_cancelBeforeExecute() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0);
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_emergencyRecovery_emitsScheduleAndCancelEvents() public {
        uint256 expectedValidAt = block.timestamp + vault.EMERGENCY_RECOVERY_DELAY();
        vm.expectEmit(true, false, false, true);
        emit IFCMVault.EmergencyRecoveryScheduled(expectedValidAt);
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit IFCMVault.EmergencyRecoveryCancelled();
        vm.prank(owner);
        vault.cancelEmergencyRecovery();
        vm.stopPrank();
    }

    function test_emergencyRecovery_executeSweepsAllAssetsToOwner() public {
        uint256 originalCollateral = 1 ether;
        vm.prank(alice);
        vault.deposit(originalCollateral, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        assertNotEq(originalYield, 0);

        assertEq(COLLATERAL_TOKEN.balanceOf(address(owner)), 0);
        assertEq(YIELD_TOKEN.balanceOf(address(owner)), 0);
        assertEq(LOAN_TOKEN.balanceOf(address(owner)), 0);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();

        vm.warp(vault.emergencyRecoveryValidAt());
        // Pre-repay the vault's debt by shares so it zeroes exactly, freeing collateral for the sweep.
        LOAN_TOKEN.mint(owner, 1e10 ether);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 0, vault.position().borrowShares, address(vault), "");
        assertEq(vault.debt(), 0);
        assertEq(vault.healthFactor(), type(uint256).max);

        vm.recordLogs();
        vault.executeEmergencyRecovery();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 0);
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), 0);
        assertEq(vault.collateral(), 0);
        assertEq(vault.debt(), 0);

        uint256 collateralOut = COLLATERAL_TOKEN.balanceOf(owner);
        uint256 yieldOut = YIELD_TOKEN.balanceOf(owner);

        assertEq(collateralOut, originalCollateral);
        assertEq(yieldOut, originalYield);

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == IFCMVault.EmergencyRecoveryExecuted.selector) {
                (uint256 collateralOutRecorded, uint256 yieldOutRecorded, uint256 loanOutRecorded) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256));

                assertEq(collateralOut, collateralOutRecorded);
                assertEq(yieldOut, yieldOutRecorded);
                assertEq(0, loanOutRecorded);
                return;
            }
        }
        revert("EmergencyRecoveryExecuted event not found");
    }

    function test_emergencyRecovery_unaccountedTokens() public {
        LOAN_TOKEN.mint(address(vault), 1 ether);
        COLLATERAL_TOKEN.mint(address(vault), 1 ether);
        YIELD_TOKEN.mint(address(vault), 1 ether);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        assertEq(LOAN_TOKEN.balanceOf(address(owner)), 1 ether);
        assertEq(COLLATERAL_TOKEN.balanceOf(address(owner)), 1 ether);
        assertEq(YIELD_TOKEN.balanceOf(address(owner)), 1 ether);
    }
}
