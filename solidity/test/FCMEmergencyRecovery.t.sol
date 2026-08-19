// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract FCMEmergencyRecoveryTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    bytes errorBobUnauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(bob));
    bytes errorNotReady = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryNotReady.selector);
    bytes errorActive = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);

    function setUp() public {
        deployVault();
    }

    function test_OnlyOwner() public {
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

    function test_RecoveryDelay() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        uint256 snapshot = vm.snapshot();

        assertEq(vault.emergencyRecoveryValidAt(), block.timestamp + vault.EMERGENCY_RECOVERY_DELAY());
        assertEq(vault.emergencyRecoveryActive(), true);
        vm.warp(vault.emergencyRecoveryValidAt() - 1);

        vm.expectRevert(errorNotReady);
        vault.executeEmergencyRecovery();

        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.revertTo(snapshot);
        vm.warp(vault.emergencyRecoveryValidAt() * 2);
        vault.executeEmergencyRecovery();
    }

    function test_doubleSchedule() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vault.scheduleEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), block.timestamp + vault.EMERGENCY_RECOVERY_DELAY());
        assertEq(vault.emergencyRecoveryActive(), true);
    }

    function test_cancelNotScheduled() public {
        vm.startPrank(owner);
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0, "recovery not scheduled");
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_doubleCancel() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vault.cancelEmergencyRecovery();
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0, "recovery not scheduled");
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_noCancelAfterExecute() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        uint64 emergencyRecoveryValidAt = vault.emergencyRecoveryValidAt();
        vm.warp(emergencyRecoveryValidAt);
        vault.executeEmergencyRecovery();
        assertEq(emergencyRecoveryValidAt, vault.emergencyRecoveryValidAt());
        vm.expectRevert(errorActive);
        vault.cancelEmergencyRecovery();
    }

    function test_cancelBeforeExecute() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.cancelEmergencyRecovery();
        assertEq(vault.emergencyRecoveryValidAt(), 0, "recovery not scheduled");
        assertEq(vault.emergencyRecoveryActive(), false);
    }

    function test_events() public {
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

    function test_happyPath() public {
        setCollateralPrice(10 ether);
        setYieldPrice(0.1 ether);
        uint256 originalCollateral = 1 ether;
        vault.depositFor(alice, originalCollateral);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        assertNotEq(originalYield, 0, "originalYield should not be 0");

        assertEq(COLLATERAL_TOKEN.balanceOf(address(owner)), 0);
        assertEq(YIELD_TOKEN.balanceOf(address(owner)), 0);
        assertEq(LOAN_TOKEN.balanceOf(address(owner)), 0);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();

        vm.warp(vault.emergencyRecoveryValidAt());
        LOAN_TOKEN.mint(owner, 1e10 ether);
        LOAN_TOKEN.approve(address(vault), type(uint256).max);
        MarketLib.repayAll(vault.market());

        vm.recordLogs();
        vault.executeEmergencyRecovery();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 0);
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), 0);
        assertEq(MarketLib.collateral(vault.market()), 0);
        assertEq(MarketLib.debt(vault.market()), 0);

        uint256 collateralOut = COLLATERAL_TOKEN.balanceOf(owner);
        uint256 yieldOut = YIELD_TOKEN.balanceOf(owner);

        assertEq(collateralOut, originalCollateral, "collateralOut should be originalCollateral");
        assertEq(yieldOut, originalYield, "yieldOut should be originalYield");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == IFCMVault.EmergencyRecoveryExecuted.selector) {
                (uint256 collateralOutRecorded, uint256 yieldOutRecorded, uint256 loanOutRecorded) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256));

                assertEq(collateralOut, collateralOutRecorded);
                assertEq(yieldOut, yieldOutRecorded);
                assertEq(0, loanOutRecorded, "loanOutRecorded should be 0");
                return;
            }
        }
        revert("EmergencyRecoveryExecuted event not found");
    }

    function test_unaccountedTokens() public {
        LOAN_TOKEN.mint(address(vault), 1 ether);
        COLLATERAL_TOKEN.mint(address(vault), 1 ether);
        YIELD_TOKEN.mint(address(vault), 1 ether);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        assertEq(LOAN_TOKEN.balanceOf(address(owner)), 1 ether, "loan not swept");
        assertEq(COLLATERAL_TOKEN.balanceOf(address(owner)), 1 ether, "collateral not swept");
        assertEq(YIELD_TOKEN.balanceOf(address(owner)), 1 ether, "yield not swept");
    }
}
