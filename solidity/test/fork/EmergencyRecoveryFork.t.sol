// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../../src/libraries/FCMHelpers.sol";
import {ForkDeployers} from "./ForkDeployers.sol";

/// @dev `executeEmergencyRecovery` withdraws all collateral without repaying, so real Morpho's
/// `withdrawCollateral` health check only lets it through at `borrowShares == 0` - the external
/// pre-repay documented on `IFCMVault.executeEmergencyRecovery` is mandatory, not advisory.
/// `MockMorpho` enforces no health check, so this can only be covered on a fork.
contract EmergencyRecoveryForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;

    uint256 constant DEPOSIT_AMOUNT = 1e8; // 1 WBTC

    address internal repayer = makeAddr("repayer");

    function setUp() public {
        _forkSetup();
        _fundArb();
        _depositUsers(1, DEPOSIT_AMOUNT);
        _arbPoolToSpot();
    }

    function test_emergencyRecoveryFork_externalRepayThenExecuteSucceeds() public {
        assertGt(vault.debt(), 0, "vault carries debt in normal operation");

        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());

        _externalRepayFullDebt();

        assertEq(vault.debt(), 0, "debt cleared by the external repayer");
        assertEq(vault.healthFactor(), type(uint256).max, "no debt -> unliquidatable");

        uint256 expectedCollateralOut = WBTC.balanceOf(address(vault)) + vault.collateral();
        uint256 expectedYieldOut = FUSDEV.balanceOf(address(vault));
        uint256 expectedLoanOut = PYUSD0.balanceOf(address(vault));
        assertGt(expectedCollateralOut, 0, "there is collateral to sweep");
        assertGt(expectedYieldOut, 0, "there is yield to sweep");

        uint256 ownerCollateralBefore = WBTC.balanceOf(owner);
        uint256 ownerYieldBefore = FUSDEV.balanceOf(owner);
        uint256 ownerLoanBefore = PYUSD0.balanceOf(owner);

        vm.expectEmit(false, false, false, true);
        emit IFCMVault.EmergencyRecoveryExecuted(expectedCollateralOut, expectedYieldOut, expectedLoanOut);
        vault.executeEmergencyRecovery();

        assertTrue(vault.emergencyRecovered(), "recovery marked executed");
        assertEq(vault.collateral(), 0, "morpho collateral withdrawn");
        assertEq(vault.debt(), 0, "no debt reopened");
        assertEq(WBTC.balanceOf(address(vault)), 0, "no collateral left in the vault");
        assertEq(FUSDEV.balanceOf(address(vault)), 0, "no yield left in the vault");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan token left in the vault");

        assertEq(WBTC.balanceOf(owner) - ownerCollateralBefore, expectedCollateralOut, "collateral swept to owner");
        assertEq(FUSDEV.balanceOf(owner) - ownerYieldBefore, expectedYieldOut, "yield swept to owner");
        assertEq(PYUSD0.balanceOf(owner) - ownerLoanBefore, expectedLoanOut, "loan token swept to owner");
    }

    function test_emergencyRecoveryFork_executeRevertsWhileDebtOutstanding() public {
        assertGt(vault.debt(), 0, "vault carries debt");
        assertGe(vault.healthFactor(), HEALTH_FACTOR_MIN, "position is healthy, not distressed");

        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());

        vm.expectRevert(bytes("insufficient collateral"));
        vault.executeEmergencyRecovery();

        // rebalance only delevers to HEALTH_FACTOR_MIN_TARGET, so it cannot unblock the sweep.
        vault.rebalance();
        _arbPoolToSpot();
        assertGt(vault.debt(), 0, "rebalance cannot reach zero debt");

        vm.expectRevert(bytes("insufficient collateral"));
        vault.executeEmergencyRecovery();
    }

    /// @dev Why the repay and the sweep must land in one transaction: in between, the vault is
    /// debt-free and `redeem` stays open during a pending recovery.
    function test_emergencyRecoveryFork_repayIsFrontRunnableWhenNotAtomic() public {
        address holder = makeAddr("user0");
        uint256 shares = vault.balanceOf(holder);
        assertGt(shares, 0, "holder has shares");

        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());

        uint256 navBeforeRepay = vault.totalAssets();
        _externalRepayFullDebt();
        assertGt(vault.totalAssets(), navBeforeRepay, "the repay is a gift to NAV");

        vm.prank(holder);
        uint256 assetsOut = vault.redeem(shares, holder, holder);
        assertGt(assetsOut, DEPOSIT_AMOUNT, "holder front-runs the sweep and exits above principal");
    }

    /// @dev Repays by shares, not assets: only a zeroed `borrowShares` short-circuits Morpho's
    /// health check. Repaying `debt()` leaves dust shares and the sweep still reverts.
    function _externalRepayFullDebt() internal {
        uint256 borrowShares = uint256(vault.position().borrowShares);
        assertGt(borrowShares, 0, "there is a borrow position to clear");

        deal(address(PYUSD0), repayer, vault.debt() * 2 + 1e6);

        vm.startPrank(repayer);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        (uint256 assetsRepaid,) = MORPHO.repay(mp, 0, borrowShares, address(vault), "");
        vm.stopPrank();

        assertGt(assetsRepaid, 0, "repayer paid the debt");
        assertEq(uint256(vault.position().borrowShares), 0, "borrow shares zeroed exactly");
    }
}
