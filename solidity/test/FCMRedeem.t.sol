// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMRedeemTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        vault.grantFundApprove(alice, 1 ether);
        vm.prank(alice);
        vault.approve(address(vault), type(uint256).max);
        vault.grantFundApprove(bob, 1 ether);
        vm.prank(bob);
        vault.approve(address(vault), type(uint256).max);
    }

    function test_redeem_roundTripReturnsApproximatelyDeposited() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertEq(COLLATERAL_TOKEN.balanceOf(alice), assetsOut);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_redeem_burnsSharesAndTransfersToReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, carol, alice);

        assertEq(COLLATERAL_TOKEN.balanceOf(carol), assetsOut);
        assertApproxEqAbs(COLLATERAL_TOKEN.balanceOf(carol), 1 ether, 2);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_redeem_partialRedeemUnwindsProportionalSlice() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        uint256 debtBefore = vaultHarness.exposed_debt();
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares / 2, alice, alice);

        assertApproxEqAbs(assetsOut, 0.5 ether, 2);
        assertApproxEqAbs(vault.balanceOf(alice), shares / 2, 1);
        assertApproxEqAbs(COLLATERAL_TOKEN.balanceOf(address(alice)), assetsOut, 1);
        assertApproxEqRel(vaultHarness.exposed_debt(), debtBefore / 2, 1);
        assertApproxEqRel(YIELD_TOKEN.balanceOf(address(vault)), yieldBefore / 2, 1);
    }

    function test_redeem_twoDepositorsIndependentRedeem() public {
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(1 ether, alice);
        vm.prank(bob);
        uint256 sharesBob = vault.deposit(1 ether, bob);

        vm.prank(alice);
        uint256 assetsOutAlice = vault.redeem(sharesAlice, alice, alice);

        assertApproxEqRel(assetsOutAlice, 1 ether, 2);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), sharesBob);
    }

    function test_redeem_noRevertForNoEarlyAccessRedeemer() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.revokeEarlyAccess(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    function test_redeem_noRevertForNonEarlyAccessReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.redeem(shares, stranger, alice);
    }

    function test_redeem_noRevertForNonEarlyAccessOwner() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.approve(address(stranger), shares);

        vm.prank(stranger);
        vault.redeem(shares, stranger, alice);
    }

    function test_redeem_revertsIfNotOwnerAndNoAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.expectRevert(Errors.noAllowance(stranger, 0, shares));
        vm.prank(stranger);
        vault.redeem(shares, stranger, alice);
    }

    function test_redeem_reduceAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        vault.approve(address(stranger), shares / 2 + 1);

        vm.prank(stranger);
        vault.redeem(shares / 2, stranger, alice);

        vm.expectRevert(Errors.noAllowance(stranger, 1, 2));
        vm.prank(stranger);
        vault.redeem(2, stranger, alice);
    }

    function test_redeem_surplusOnYieldAccrual() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE.mulDiv(110, 100));

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertGt(assetsOut, 1 ether);
    }

    function test_redeem_fillsYieldShortfallFromCollateral() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE.mulDiv(100, 110));

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertLt(assetsOut, 1 ether);
    }

    function test_redeem_fullCollateralNeededToCoverDebt() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setYieldPrice(1);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(100, 115));

        MORPHO.drainLiquidity(vault.market(), COLLATERAL_TOKEN.balanceOf(address(MORPHO)));
        vm.expectRevert();
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        MORPHO.supplyLiquidity(vault.market(), 2 ether);
        vm.prank(alice);
        assetsOut = vault.redeem(shares, alice, alice);

        assertLt(assetsOut, 0.4 ether);
    }

    function test_redeem_zeroSharesIsNoop() public {
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(0, alice, alice);

        assertEq(assetsOut, 0);
    }

    function testFuzz_redeem_rebalanceAfterDebtDustDonation(uint256 depositAmount) public {
        // A debt-dust donation can make redeem revert, so a rebalance may be needed.
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
        depositAmount = bound(depositAmount, 1, 1e18);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        Position memory position = vault.position();
        console.log("position.borrowShares", position.borrowShares);
        LOAN_TOKEN.mint(address(this), 1e30);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 0, position.borrowShares - 1, address(vault), "");

        vm.startPrank(alice);
        try vault.redeem(shares, alice, alice) {
            return;
        } catch {
            vault.rebalance();
            vault.redeem(shares, alice, alice);
        }
    }

    function test_redeem_noSlippageProtectionAcceptsAnyPrice() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setYieldPoolPrice(YIELD_PRICE / 100);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertLt(assetsOut, 0.5 ether);
    }

    function test_redeem_feesAccrue() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 actualFeeShares = vault.balanceOf(carol);
        assertGt(actualFeeShares, 0);
    }

    function test_redeem_revertsOnNeededDelever() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE / 2);

        vm.expectRevert(Errors.vaultUnhealthy());
        vm.prank(alice);
        vault.redeem(1 ether, alice, alice);
    }

    function test_redeem_emitsSnapshot() public {
        setCollateralPrice(2e36);
        setYieldPrice(4e36);
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        uint256 depositHealth = (HEALTH_FACTOR_MAX_TARGET + HEALTH_FACTOR_MIN_TARGET) / 2;
        uint256 debt = uint256(1 ether).mulDiv(MARKET_LLTV, depositHealth);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(0.5 ether + 1, debt + 1, debt / 4 + 1, 2e36, 1e36, 4e36);
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);
    }

    function test_redeem_noRevertDuringEmergencyRecovery() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vm.prank(alice);
        vault.redeem(1 ether, alice, alice);
    }

    function test_redeem_caseB_selfCollateralizedNoIdleLoanLiquidity() public {
        setCollateralPrice(1e36); // 1:1 so debtToCollateral matches the mock swap
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        // Deep Case B: burn 60% of the vault's yield so the held yield can't cover the slice.
        YIELD_TOKEN.burn(address(vault), YIELD_TOKEN.balanceOf(address(vault)) * 6 / 10);
        // Buffer only collateral in the singleton; keep loan at zero so a loan-token flash
        // could not be served here.
        COLLATERAL_TOKEN.mint(address(MORPHO), 2 ether);
        assertEq(LOAN_TOKEN.balanceOf(address(MORPHO)), 0);
        uint256 fairValue = vault.convertToAssets(shares);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertApproxEqRel(assetsOut, fairValue, 0.02e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_redeem_staysOpenDuringPendingRecovery() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGt(assets, 0);
    }

    function test_redeem_operatorSpendsAllowanceAndIsPaid() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        address operator = address(0xCAFE);
        vm.prank(alice);
        vault.approve(operator, shares);

        vm.prank(operator);
        uint256 assetsOut = vault.redeem(shares, operator, alice);

        assertEq(vault.allowance(alice, operator), 0);
        assertEq(COLLATERAL_TOKEN.balanceOf(operator), assetsOut);
        assertEq(vault.balanceOf(alice), 0);
    }
}
