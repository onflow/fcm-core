// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMDepositTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;
    bytes errorActive = Errors.emergencyRecoveryActive();

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        grantFundApprove(bob, 1 ether);
    }

    function test_deposit_firstDepositMintsDecimalOffsetShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        assertEq(shares, 1 ether * 1e6);
    }

    function test_deposit_pullsAllAssetsAsCollateral() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertEq(COLLATERAL_TOKEN.balanceOf(alice), 0);
        assertEq(vault.collateral(), 1 ether);
        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 0);
        assertGe(vault.ltv(), LTV_MIN);
        assertLe(vault.ltv(), LTV_MAX);
    }

    function test_deposit_takesOutLoan() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertGt(vault.debt(), 0);
        assertGe(vault.ltv(), LTV_MIN);
        assertLe(vault.ltv(), LTV_MAX);
    }

    function test_deposit_blockedDuringEmergencyRecovery() public {
        vm.prank(owner);
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

    function test_deposit_blockedAfterEmergencyRecovery() public {
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

    function test_deposit_belowLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        uint256 shares = vault.deposit(500, alice);
        assertGt(shares, 0);
    }

    function test_deposit_exactlyAtLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);
    }

    function test_deposit_oneOverLimitReverts() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vm.expectRevert(Errors.erc4626ExceededMaxDeposit(alice, 1001, 1000));
        vault.deposit(1001, alice);
    }

    function test_deposit_limitIsGlobalAcrossUsers() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);

        vm.prank(alice);
        vault.deposit(600, alice);

        vm.prank(bob);
        vm.expectRevert(Errors.erc4626ExceededMaxDeposit(bob, 500, 400));
        vault.deposit(500, bob);

        vm.prank(bob);
        vault.deposit(400, bob);
    }

    function test_deposit_healthAtBandMidpoint() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 midPoint = (LTV_MIN + LTV_MAX) / 2;
        assertApproxEqAbs(vault.ltv(), midPoint, 1);
    }

    /// @dev A deposit into a healthy (in-band) position moves LTV toward the deposit target
    /// (band midpoint) but never past it. When the position is below the target (under-levered),
    /// a deposit raises LTV toward the target; once at the target, further deposits hold there.
    function test_deposit_raisesLtvTowardTargetWhileBelowIt() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 target = (LTV_MIN + LTV_MAX) / 2;
        assertApproxEqAbs(vault.ltv(), target, 1);

        // Collateral appreciates -> LTV drops below the deposit target.
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(110, 100));
        uint256 ltvBefore = vault.ltv();
        assertLt(ltvBefore, target);

        vm.prank(bob);
        vault.deposit(1 ether, bob);

        // The deposit raises LTV toward the target (capped by the existing position's
        // headroom), but never past it.
        assertGt(vault.ltv(), ltvBefore);
        assertLe(vault.ltv(), target + 0.01e18);
    }

    /// @dev A deposit into a position already at the deposit target keeps LTV at the target:
    /// the new collateral borrows its own proportional share at the target, not more.
    function test_deposit_holdsLtvAtTargetOnceThere() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 target = (LTV_MIN + LTV_MAX) / 2;
        assertApproxEqAbs(vault.ltv(), target, 1);

        uint256 ltvBefore = vault.ltv();

        vm.prank(bob);
        vault.deposit(1 ether, bob);

        assertApproxEqAbs(vault.ltv(), ltvBefore, 0.01e18);
    }

    function test_deposit_revertsWhenTvlLimitLoweredBelowTvl() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(800, alice);

        vm.prank(owner);
        vault.setMaxTvl(500);
        vm.prank(alice);
        vm.expectRevert(Errors.erc4626ExceededMaxDeposit(alice, 1, 0));
        vault.deposit(1, alice);
    }

    function test_deposit_tracksMaxTvlChanges() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);

        vm.prank(owner);
        vault.setMaxTvl(2500);
        vm.prank(alice);
        vault.deposit(1500, alice);
    }

    function test_deposit_twoDepositorsSharesAreProRata() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1 ether, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1 ether, bob);
        assertEq(bobShares, aliceShares);
    }

    function test_deposit_revertsWhenUnderwater() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE / 3);
        setYieldPrice(YIELD_PRICE / 3);

        vm.prank(bob);
        vm.expectRevert(Errors.vaultUnderwater());
        vault.deposit(1 ether, bob);
    }

    function test_deposit_doesNotRebalanceWholeProtocol() public {
        vm.prank(alice);
        vault.deposit(0.5 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 originalDebt = vault.debt();

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(1000, 100));

        vm.prank(alice);
        vault.deposit(0.5 ether, alice);

        uint256 newYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 newDebt = vault.debt();
        uint256 expectedYield = originalYield * 11;
        uint256 expectedDebt = originalDebt * 11;
        assertApproxEqRel(newYield, expectedYield, 0.0001e18);
        assertApproxEqRel(newDebt, expectedDebt, 0.0001e18);
    }

    function test_deposit_zero() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(0, alice);
        assertEq(shares, 0);
    }

    function test_deposit_noBorrowWhenPositionUnhealthy() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 originalDebt = vault.debt();

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(50, 100));
        vm.prank(bob);
        vault.deposit(1 ether, bob);

        assertEq(vault.debt(), originalDebt);
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_deposit_feesAccrueToRecipientOnDeposit() public {
        vm.prank(alice);
        vault.deposit(0.5 ether, alice);

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);
        vm.stopPrank();

        assertEq(vault.balanceOf(carol), 0);

        vm.prank(alice);
        vault.deposit(0.5 ether, alice);

        assertGt(vault.balanceOf(carol), 0);
    }

    function test_deposit_noSlippageProtectionAcceptsAnyPrice() public {
        setYieldPoolPrice(YIELD_PRICE * 100);
        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_deposit_revertsOnIlliquidMorpho() public {
        MORPHO.setBorrowCap(vault.market(), 1);

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1 ether, alice);
    }

    function test_deposit_revertsForNonAllowlistedReceiver() public {
        COLLATERAL_TOKEN.mint(stranger, 1 ether);
        vm.prank(stranger);
        COLLATERAL_TOKEN.approve(address(vault), 1 ether);
        vm.expectRevert(Errors.noEarlyAccess(stranger));
        vm.prank(stranger);
        vault.deposit(1 ether, stranger);
    }

    // A fresh deposit lands at the band midpoint with no yield surplus, so
    // harvest and rebalance are no-ops regardless of deposit size.
    function testFuzz_deposit_harvestAndRebalanceNoopWhenNoSurplus(uint256 bobAmount) public {
        bobAmount = bound(bobAmount, 0.01 ether, 100 ether);

        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        COLLATERAL_TOKEN.mint(bob, bobAmount);
        vm.startPrank(bob);
        COLLATERAL_TOKEN.approve(address(vault), bobAmount);
        vault.deposit(bobAmount, bob);
        vm.stopPrank();

        uint256 collBefore = vault.collateral();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));
        uint256 debtBefore = vault.debt();
        uint256 ltvBefore = vault.ltv();

        vault.harvest(type(uint256).max);
        vault.rebalance();

        assertApproxEqAbs(vault.collateral(), collBefore, 1);
        assertApproxEqAbs(YIELD_TOKEN.balanceOf(address(vault)), yieldBefore, 1);
        assertApproxEqAbs(vault.debt(), debtBefore, 1);
        assertApproxEqAbs(vault.ltv(), ltvBefore, 1e15);
    }

    function test_deposit_emitsVaultStateSnapshot() public {
        setCollateralPrice(2e36);
        setYieldPrice(4e36);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 coll = vault.collateral();
        uint256 debt = vault.debt();
        uint256 yieldBal = YIELD_TOKEN.balanceOf(address(vault));
        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(coll, debt, yieldBal, 2e36, 4e36);
        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_deposit_CollateralDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        deal(address(COLLATERAL_TOKEN), address(vault), 10 ether);

        vm.prank(bob);
        vault.deposit(1 ether, bob);
        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 10 ether);
    }

    function test_deposit_LoanDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        deal(address(LOAN_TOKEN), address(vault), 10 ether);

        vm.prank(bob);
        vault.deposit(1 ether, bob);
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 10 ether);
    }
}
