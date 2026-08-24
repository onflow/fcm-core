// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

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

    /// @dev The sweep withdraws all collateral without repaying, so Morpho's health check only clears it at zero
    /// debt - the debt must be repaid out-of-band first. `EmergencyRecoveryFork.t.sol` pins the same on real Morpho.
    function test_emergencyRecovery_executeRevertsWhileDebtOutstanding() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        assertGt(vault.debt(), 0);
        assertGe(vault.ltv(), LTV_MIN);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());

        vm.expectRevert(bytes("insufficient collateral"));
        vault.executeEmergencyRecovery();
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
        assertEq(vault.ltv(), 0);

        uint256 snap = vm.snapshotState();
        vault.executeEmergencyRecovery();

        uint256 collateralOut = COLLATERAL_TOKEN.balanceOf(owner);
        uint256 yieldOut = YIELD_TOKEN.balanceOf(owner);
        vm.revertToState(snap);

        vm.expectEmit(false, false, false, true);
        emit IFCMVault.EmergencyRecoveryExecuted(collateralOut, yieldOut, 0);
        vault.executeEmergencyRecovery();

        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 0);
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), 0);
        assertEq(vault.collateral(), 0);
        assertEq(vault.debt(), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(owner), originalCollateral);
        assertEq(YIELD_TOKEN.balanceOf(owner), originalYield);
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
