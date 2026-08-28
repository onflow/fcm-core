// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";

/// @title FCMDependencyFailures
/// @notice Verifies the availability matrix in `docs/security-surface.md`: for each external dependency taken
/// offline, which state-modifying functions halt and which exit paths stay open.
contract FCMDependencyFailuresTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);
        grantFundApprove(alice, 1 ether);
        grantFundApprove(bob, 1 ether);

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        assertGt(vault.debt(), 0);
        assertGt(YIELD_TOKEN.balanceOf(address(vault)), 0);
    }

    function test_dependencyFailure_morpho_revertsOnDeposit() public {
        MORPHO.setShouldRevert(true);
        vm.prank(bob);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.deposit(1 ether, bob);
    }

    function test_dependencyFailure_morpho_revertsOnRedeem() public {
        uint256 aliceShares = vault.balanceOf(alice);
        MORPHO.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.redeem(aliceShares, alice, alice);
    }

    function test_dependencyFailure_morpho_revertsOnRebalance() public {
        MORPHO.setShouldRevert(true);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.rebalance();
    }

    function test_dependencyFailure_morpho_revertsOnHarvest() public {
        MORPHO.setShouldRevert(true);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.harvest(type(uint256).max);
    }

    function test_dependencyFailure_morpho_revertsOnRedeemInKind() public {
        uint256 aliceShares = vault.balanceOf(alice);
        MORPHO.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.redeemInKind(aliceShares, alice, alice);
    }

    /// @dev Recovery sweeps collateral via `MORPHO.withdrawCollateral`, so a Morpho outage halts it too.
    function test_dependencyFailure_morpho_revertsOnExecuteEmergencyRecovery() public {
        _zeroDebt();
        _scheduleAndWarpRecovery();
        MORPHO.setShouldRevert(true);
        vm.prank(owner);
        vm.expectRevert("MOCK_MORPHO_DOWN");
        vault.executeEmergencyRecovery();
    }

    function test_dependencyFailure_marketOracle_revertsOnDeposit() public {
        COLLATERAL_ORACLE.setShouldRevert(true);
        vm.prank(bob);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.deposit(1 ether, bob);
    }

    function test_dependencyFailure_marketOracle_revertsOnRedeem() public {
        uint256 aliceShares = vault.balanceOf(alice);
        COLLATERAL_ORACLE.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.redeem(aliceShares, alice, alice);
    }

    function test_dependencyFailure_marketOracle_revertsOnRebalance() public {
        COLLATERAL_ORACLE.setShouldRevert(true);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.rebalance();
    }

    function test_dependencyFailure_marketOracle_revertsOnHarvest() public {
        COLLATERAL_ORACLE.setShouldRevert(true);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.harvest(type(uint256).max);
    }

    function test_dependencyFailure_marketOracle_revertsOnRedeemInKind() public {
        uint256 aliceShares = vault.balanceOf(alice);
        COLLATERAL_ORACLE.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.redeemInKind(aliceShares, alice, alice);
    }

    function test_dependencyFailure_marketOracle_executeEmergencyRecoverySucceeds() public {
        _zeroDebt();
        _scheduleAndWarpRecovery();
        COLLATERAL_ORACLE.setShouldRevert(true);

        uint256 collBefore = vault.collateral();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));
        assertGt(collBefore, 0);
        assertGt(yieldBefore, 0);

        vm.prank(owner);
        vault.executeEmergencyRecovery();

        assertEq(vault.collateral(), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(owner), collBefore);
        assertEq(YIELD_TOKEN.balanceOf(owner), yieldBefore);
        assertTrue(vault.emergencyRecovered());
    }

    function test_dependencyFailure_yieldOracle_revertsOnDeposit() public {
        YIELD_ORACLE.setShouldRevert(true);
        vm.prank(bob);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.deposit(1 ether, bob);
    }

    function test_dependencyFailure_yieldOracle_revertsOnRedeem() public {
        uint256 aliceShares = vault.balanceOf(alice);
        YIELD_ORACLE.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.redeem(aliceShares, alice, alice);
    }

    function test_dependencyFailure_yieldOracle_revertsOnRebalance() public {
        YIELD_ORACLE.setShouldRevert(true);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.rebalance();
    }

    function test_dependencyFailure_yieldOracle_revertsOnHarvest() public {
        YIELD_ORACLE.setShouldRevert(true);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.harvest(type(uint256).max);
    }

    function test_dependencyFailure_yieldOracle_revertsOnRedeemInKind() public {
        uint256 aliceShares = vault.balanceOf(alice);
        YIELD_ORACLE.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_ORACLE_DOWN");
        vault.redeemInKind(aliceShares, alice, alice);
    }

    function test_dependencyFailure_yieldOracle_executeEmergencyRecoverySucceeds() public {
        _zeroDebt();
        _scheduleAndWarpRecovery();
        YIELD_ORACLE.setShouldRevert(true);

        uint256 collBefore = vault.collateral();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(owner);
        vault.executeEmergencyRecovery();

        assertEq(vault.collateral(), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(owner), collBefore);
        assertEq(YIELD_TOKEN.balanceOf(owner), yieldBefore);
        assertTrue(vault.emergencyRecovered());
    }

    /// @dev Collateral price is raised so the new deposit has headroom to borrow (and thus swap). At the
    /// post-first-deposit target a second deposit would borrow 0 and skip the swap.
    function test_dependencyFailure_yieldLoanPool_revertsOnDeposit() public {
        setCollateralPrice((COLLATERAL_PRICE * 150) / 100);
        YIELD_LOAN_POOL.setShouldRevert(true);
        vm.prank(bob);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.deposit(1 ether, bob);
    }

    function test_dependencyFailure_yieldLoanPool_revertsOnRedeem() public {
        uint256 aliceShares = vault.balanceOf(alice);
        YIELD_LOAN_POOL.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.redeem(aliceShares, alice, alice);
    }

    /// @dev Push LTV above LTV_MAX so rebalance must delever (sell yield -> loan -> repay).
    function test_dependencyFailure_yieldLoanPool_revertsOnRebalance() public {
        setCollateralPrice((COLLATERAL_PRICE * 90) / 100);
        assertGt(vault.ltv(), LTV_MAX);
        YIELD_LOAN_POOL.setShouldRevert(true);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.rebalance();
    }

    /// @dev Raise the yield price so a surplus appears, forcing harvest to swap yield -> loan.
    function test_dependencyFailure_yieldLoanPool_revertsOnHarvest() public {
        setYieldPrice(YIELD_PRICE * 2);
        YIELD_LOAN_POOL.setShouldRevert(true);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.harvest(type(uint256).max);
    }

    /// @dev `redeemInKind` repays the caller's debt slice directly — no swap involved.
    function test_dependencyFailure_yieldLoanPool_redeemInKindSucceeds() public {
        uint256 shares = vault.balanceOf(alice);
        // Alice holds 100% of shares, so her debt slice is the full position debt (rounded up).
        uint256 loanNeeded = vault.debt() * 2;
        LOAN_TOKEN.mint(alice, loanNeeded);
        vm.startPrank(alice);
        LOAN_TOKEN.approve(address(vault), loanNeeded);
        YIELD_LOAN_POOL.setShouldRevert(true);
        (uint256 collateralOut, uint256 yieldOut) = vault.redeemInKind(shares, alice, alice);
        vm.stopPrank();

        assertGt(collateralOut, 0);
        assertGt(yieldOut, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_dependencyFailure_yieldLoanPool_executeEmergencyRecoverySucceeds() public {
        _zeroDebt();
        _scheduleAndWarpRecovery();
        YIELD_LOAN_POOL.setShouldRevert(true);

        uint256 collBefore = vault.collateral();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(owner);
        vault.executeEmergencyRecovery();

        assertEq(vault.collateral(), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(owner), collBefore);
        assertEq(YIELD_TOKEN.balanceOf(owner), yieldBefore);
        assertTrue(vault.emergencyRecovered());
    }

    /// @dev Raise the yield price so selling the yield slice on redeem produces more loan than the debt slice needs,
    /// forcing the excess through the collateral/loan pool (`onMorphoRepay` -> `_swapLoanToCollateral`).
    function test_dependencyFailure_collateralLoanPool_revertsOnRedeem() public {
        setYieldPrice(YIELD_PRICE * 2);
        uint256 aliceShares = vault.balanceOf(alice);
        COLLATERAL_LOAN_POOL.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.redeem(aliceShares, alice, alice);
    }

    /// @dev Harvest leg 2 swaps loan -> collateral on the collateral/loan pool.
    function test_dependencyFailure_collateralLoanPool_revertsOnHarvest() public {
        setYieldPrice(YIELD_PRICE * 2);
        COLLATERAL_LOAN_POOL.setShouldRevert(true);
        vm.expectRevert("MOCK_POOL_DOWN");
        vault.harvest(type(uint256).max);
    }

    /// @dev Deposit and rebalance only touch the yield/loan pool, so the collateral/loan pool being down does not
    /// affect them.
    function test_dependencyFailure_collateralLoanPool_depositSucceeds() public {
        setCollateralPrice((COLLATERAL_PRICE * 150) / 100);
        COLLATERAL_LOAN_POOL.setShouldRevert(true);
        vm.prank(bob);
        vault.deposit(1 ether, bob);
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_dependencyFailure_collateralLoanPool_redeemInKindSucceeds() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 loanNeeded = vault.debt() * 2;
        LOAN_TOKEN.mint(alice, loanNeeded);
        vm.startPrank(alice);
        LOAN_TOKEN.approve(address(vault), loanNeeded);
        COLLATERAL_LOAN_POOL.setShouldRevert(true);
        (uint256 collateralOut, uint256 yieldOut) = vault.redeemInKind(shares, alice, alice);
        vm.stopPrank();

        assertGt(collateralOut, 0);
        assertGt(yieldOut, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_dependencyFailure_collateralLoanPool_executeEmergencyRecoverySucceeds() public {
        _zeroDebt();
        _scheduleAndWarpRecovery();
        COLLATERAL_LOAN_POOL.setShouldRevert(true);

        uint256 collBefore = vault.collateral();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(owner);
        vault.executeEmergencyRecovery();

        assertEq(vault.collateral(), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(owner), collBefore);
        assertEq(YIELD_TOKEN.balanceOf(owner), yieldBefore);
        assertTrue(vault.emergencyRecovered());
    }

    /// @dev Pre-repay the vault's entire debt out-of-band (directly via Morpho, not through the vault) so the position
    /// is debt-free and `executeEmergencyRecovery` can sweep collateral.
    function _zeroDebt() internal {
        uint256 borrowShares = vault.position().borrowShares;
        assertGt(borrowShares, 0);
        LOAN_TOKEN.mint(owner, vault.debt() * 2);
        vm.startPrank(owner);
        MORPHO.repay(vault.market(), 0, borrowShares, address(vault), "");
        vm.stopPrank();
        assertEq(vault.debt(), 0);
        assertEq(vault.ltv(), 0);
    }

    function _scheduleAndWarpRecovery() internal {
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
    }
}
