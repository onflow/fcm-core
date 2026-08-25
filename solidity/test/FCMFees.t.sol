// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract FCMFeesTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();

        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
    }

    function test_fees_defaultFees() public view {
        assertEq(vault.managementFeeBps(), 0);
        assertEq(vault.performanceFeeBps(), 0);
    }

    function test_fees_setFeesOnlyOwner() public {
        vm.expectRevert(Errors.ownableUnauthorizedAccount(stranger));
        vm.prank(stranger);
        vault.setManagementFeeBps(100);
        vm.expectRevert(Errors.ownableUnauthorizedAccount(stranger));
        vm.prank(stranger);
        vault.setPerformanceFeeBps(100);
    }

    function test_fees_setValidFees() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setPerformanceFeeBps(100);
        vm.stopPrank();
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.performanceFeeBps(), 100);
    }

    function test_fees_setFeesCaps() public {
        vm.expectRevert(Errors.invalidFee());
        vm.prank(owner);
        vault.setManagementFeeBps(1001);
        vm.prank(owner);
        vault.setManagementFeeBps(1000);

        vm.expectRevert(Errors.invalidFee());
        vm.prank(owner);
        vault.setPerformanceFeeBps(5001);
        vm.prank(owner);
        vault.setPerformanceFeeBps(5000);
    }

    function test_fees_setFeesEmitsEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.ManagementFeeSet(0, 100);
        vault.setManagementFeeBps(100);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.PerformanceFeeSet(0, 100);
        vault.setPerformanceFeeBps(100);
    }

    function test_fees_managementFeeClampedAtOneYear() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        vm.warp(block.timestamp + 1000 days);
        vault.accrueFees();

        assertApproxEqRel(vault.balanceOf(carol), vault.balanceOf(alice).mulDiv(1, 100), 0.011e18);
    }

    function test_fees_accruesOnNewRecipient() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        vm.warp(block.timestamp + 365 days);
        vm.prank(owner);
        vault.setFeeRecipient(stranger);

        assertApproxEqRel(vault.balanceOf(carol), vault.balanceOf(alice).mulDiv(1, 100), 0.011e18);
    }

    function test_fees_noPerformanceFeesAccrueOnOscillation() public {
        vm.startPrank(owner);
        vault.setPerformanceFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setYieldPrice(YIELD_PRICE * 2);
        vault.accrueFees();

        uint256 feeShares = vault.balanceOf(carol);

        setYieldPrice(YIELD_PRICE);
        vault.accrueFees();
        assertEq(vault.balanceOf(carol), feeShares);
        setYieldPrice(YIELD_PRICE * 2);
        vault.accrueFees();
        assertEq(vault.balanceOf(carol), feeShares);
    }

    function test_fees_recipientNotAllowlistedDoesNotRevert() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(stranger);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();
    }

    function test_fees_combinedAccrual() public {
        vm.startPrank(owner);
        vault.setPerformanceFeeBps(100);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        setYieldPrice(YIELD_PRICE * 2);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        uint256 feeShares = vault.balanceOf(carol);
        assertLt(feeShares, shares.mulDiv(2, 100));
        assertGt(feeShares, shares.mulDiv(13, 1000));
    }

    function test_fees_noRetroactiveChargeOnEnable() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        vm.startPrank(owner);
        vault.setPerformanceFeeBps(100);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        assertEq(vault.balanceOf(carol), 0);
    }

    function test_fees_noFeesOnFirstDeposit() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertEq(vault.balanceOf(carol), 0);
    }

    function test_fees_grossUpDeliversTrueRate() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(1000);
        vault.setPerformanceFeeBps(0);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        // Tight 0.1% tolerance: a naive (non-grossed) mint would land ~9.09%, far outside.
        uint256 recipientValue = vault.convertToAssets(vault.balanceOf(carol));
        assertApproxEqRel(recipientValue, vault.totalAssets() / 10, 1e15);
    }

    function test_fees_setFeeRecipientAccessAndEvent() public {
        vm.expectRevert(Errors.ownableUnauthorizedAccount(stranger));
        vm.prank(stranger);
        vault.setFeeRecipient(carol);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.FeeRecipientSet(address(0), carol);
        vault.setFeeRecipient(carol);

        assertEq(vault.feeRecipient(), carol);
    }

    function test_fees_accrueFeesIsPermissionless() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        vm.warp(block.timestamp + 365 days);

        vm.prank(stranger);
        vault.accrueFees();

        assertGt(vault.balanceOf(carol), 0);
    }

    function test_fees_initialPerfHighWaterMark() public {
        setCollateralPrice(COLLATERAL_PRICE * 100);
        setYieldPrice(YIELD_PRICE * 10_000);
        vault.accrueFees();

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertEq(vault.balanceOf(carol), 0);
    }

    function test_fees_dustDeposit() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.stopPrank();
        vm.prank(alice);
        vault.deposit(1, alice);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vault.deposit(1 ether - 1, alice);
        vault.accrueFees();

        assertEq(vault.balanceOf(carol), 0);
    }

    function test_fees_afterEmptyPeriod() public {
        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(bob);
        vault.grantEarlyAccess(bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 shares = vault.deposit(.5 ether, alice);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        vm.prank(owner);
        vault.setFeeRecipient(carol);
        vm.warp(block.timestamp + 365 days);
        setYieldPrice(YIELD_PRICE * 2);
        vm.prank(alice);
        vault.deposit(.5 ether, alice);
        vault.accrueFees();

        assertEq(vault.balanceOf(carol), 0);
    }
}
