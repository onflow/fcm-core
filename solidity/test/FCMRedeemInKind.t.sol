// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMRedeemInKindTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    uint256 constant LOAN_AMOUNT = 2000 ether;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        vm.prank(alice);
        vault.approve(address(vault), type(uint256).max);
        grantFundApprove(bob, 1 ether);
        vm.prank(bob);
        vault.approve(address(bob), type(uint256).max);

        LOAN_TOKEN.mint(alice, LOAN_AMOUNT);
        vm.prank(alice);
        LOAN_TOKEN.approve(address(vault), LOAN_AMOUNT);
    }

    function test_redeemInKind_fullExit() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 vaultYield = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(alice);
        (uint256 collateralOutReturned, uint256 yieldOutReturned) = vault.redeemInKind(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(collateralOutReturned, COLLATERAL_TOKEN.balanceOf(alice));
        assertEq(yieldOutReturned, YIELD_TOKEN.balanceOf(alice));

        assertApproxEqRel(COLLATERAL_TOKEN.balanceOf(alice), 1 ether, 0.01e18);
        assertApproxEqRel(YIELD_TOKEN.balanceOf(alice), vaultYield, 0.01e18);

        assertLt(LOAN_TOKEN.balanceOf(alice), LOAN_AMOUNT);
    }

    function test_redeemInKind_singlePositionPartialExit() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 vaultYield = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(alice);
        (uint256 collateralOutReturned, uint256 yieldOutReturned) = vault.redeemInKind(shares / 2, alice, alice);

        assertEq(vault.balanceOf(alice), shares / 2);
        assertEq(collateralOutReturned, COLLATERAL_TOKEN.balanceOf(alice));
        assertEq(yieldOutReturned, YIELD_TOKEN.balanceOf(alice));

        assertApproxEqRel(COLLATERAL_TOKEN.balanceOf(alice), 0.5 ether, 0.01e18);
        assertApproxEqRel(YIELD_TOKEN.balanceOf(alice), vaultYield / 2, 0.01e18);

        assertLt(LOAN_TOKEN.balanceOf(alice), LOAN_AMOUNT);
    }

    function test_redeemInKind_worksWhenDeAllowlisted() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.revokeEarlyAccess(alice);

        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);
    }

    function test_redeemInKind_noRevertForNonEarlyAccessReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.redeemInKind(shares, stranger, alice);
    }

    function test_redeemInKind_noRevertForNonEarlyAccessOwner() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.approve(address(stranger), shares);

        // Caller pays the loan tokens, not the owner!
        uint256 neededLoan = uint256(1 ether).mulDiv(COLLATERAL_PRICE, 1e36);
        LOAN_TOKEN.mint(stranger, neededLoan);
        vm.prank(stranger);
        LOAN_TOKEN.approve(address(vault), neededLoan);

        vm.prank(stranger);
        vault.redeemInKind(shares, stranger, alice);
    }

    function test_redeemInKind_zeroShares() public {
        vm.prank(stranger);
        (uint256 collateralOutReturned, uint256 yieldOutReturned) = vault.redeemInKind(0, stranger, stranger);

        assertEq(collateralOutReturned, 0);
        assertEq(yieldOutReturned, 0);
    }

    function test_redeemInKind_revertsIfNotOwnerAndNoAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.expectRevert(Errors.noAllowance(stranger, 0, shares));
        vm.prank(stranger);
        vault.redeemInKind(shares, stranger, alice);
    }

    function test_redeemInKind_reduceAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.approve(address(stranger), shares / 2 + 1);

        // Caller pays the loan tokens, not the owner!
        uint256 neededLoan = uint256(1 ether).mulDiv(COLLATERAL_PRICE, 1e36);
        LOAN_TOKEN.mint(stranger, neededLoan);
        vm.prank(stranger);
        LOAN_TOKEN.approve(address(vault), neededLoan);

        vm.prank(stranger);
        vault.redeemInKind(shares / 2, stranger, alice);

        vm.expectRevert(Errors.noAllowance(stranger, 1, 2));
        vm.prank(stranger);
        vault.redeemInKind(2, stranger, alice);
    }

    function test_redeemInKind_doesNotDiluteRemainingHolder() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1 ether, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1 ether, bob);

        vm.prank(alice);
        vault.redeemInKind(aliceShares, alice, alice);

        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertGe(COLLATERAL_TOKEN.balanceOf(bob), 1 ether);
    }

    function test_redeemInKind_emitsSnapshot() public {
        setCollateralPrice(2e36);
        setYieldPrice(4e36);
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.redeemInKind(shares / 2, alice, alice);

        uint256 coll = vault.collateral();
        uint256 debt = vault.debt();
        uint256 yieldBal = YIELD_TOKEN.balanceOf(address(vault));
        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(coll, debt, yieldBal, 2e36, 4e36);
        vm.prank(alice);
        vault.redeemInKind(shares / 2, alice, alice);
    }

    function test_redeemInKind_Dust() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        Position memory position = vault.position();
        LOAN_TOKEN.mint(address(this), 1e30);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 0, position.borrowShares - 1, address(vault), "");

        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(alice), 1 ether);
    }

    function test_redeemInKind_feesAccrue() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);

        uint256 actualFeeShares = vault.balanceOf(carol);
        assertGt(actualFeeShares, 0);
    }

    function test_redeemInKind_noRevertDuringEmergencyRecovery() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vm.prank(alice);

        vault.redeemInKind(shares, alice, alice);
    }
}
