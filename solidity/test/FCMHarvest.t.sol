// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMHarvestTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.startPrank(owner);
        vault.setMaxTvl(100 ether);
        vault.setMaxSlippageBps(100); // 1% — harvest/rebalance swaps use swapLimit, which no-ops at 0
        vm.stopPrank();
        grantFundApprove(alice, 1 ether);
    }

    function test_harvest_harvestsSurplusAsCollateral() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));
        uint256 collateralBefore = vault.collateral();
        uint256 ltvBefore = vault.ltv();

        setYieldPrice(YIELD_PRICE.mulDiv(200, 100));

        // Measure the realized deltas, rewind, then replay asserting the event reports exactly those.
        uint256 snapshot = vm.snapshotState();
        vault.harvest(type(uint256).max);
        uint256 yieldSold = yieldBefore - YIELD_TOKEN.balanceOf(address(vault));
        uint256 collateralAdded = vault.collateral() - collateralBefore;
        vm.revertToState(snapshot);

        vm.expectEmit(false, false, false, true);
        emit IFCMVault.Harvested(yieldSold, collateralAdded);
        vault.harvest(type(uint256).max);

        assertGt(vault.collateral(), 1.5 ether);
        assertLt(YIELD_TOKEN.balanceOf(address(vault)), yieldBefore);
        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 0);
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 0);
        // Harvest only adds collateral (debt unchanged), so LTV must strictly decrease and stay healthy.
        assertLt(vault.ltv(), ltvBefore);
        assertLt(vault.ltv(), LTV_MAX);
    }

    function testFuzz_harvest_partialYieldFill(uint16 slippageBps) public {
        slippageBps = uint16(bound(slippageBps, 1, 1000));
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 originalDebt = vault.debt();

        vm.prank(owner);
        vault.setMaxSlippageBps(slippageBps);
        setYieldPrice(YIELD_PRICE * 2);
        setYieldLoanPoolPriceImpact(1e6, 3e6);

        uint256 collateralBefore = vault.collateral();

        // The shallow, price-impacted pool stops leg 1 at the bound, so only part of the offered surplus is consumed.
        // Measure the realized deltas, rewind, then replay asserting the event reports those and not what was offered.
        uint256 snapshot = vm.snapshotState();
        vault.harvest(type(uint256).max);
        uint256 yieldSold = originalYield - YIELD_TOKEN.balanceOf(address(vault));
        uint256 collateralAdded = vault.collateral() - collateralBefore;
        vm.revertToState(snapshot);
        assertGt(yieldSold, 0);

        vm.expectEmit(false, false, false, true);
        emit IFCMVault.Harvested(yieldSold, collateralAdded);
        vault.harvest(type(uint256).max);

        assertEq(vault.debt(), originalDebt);
    }

    function test_harvest_revertsWhenMispricedYieldLoan() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 yieldPrice = YIELD_PRICE.mulDiv(200, 100);
        setYieldPrice(yieldPrice);
        setYieldPoolPrice(yieldPrice.mulDiv(98_999, 100_000));
        vm.expectRevert();
        vault.harvest(type(uint256).max);
    }

    function test_harvest_revertsWhenMispricedLoanCollateral() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE.mulDiv(1000, 100));
        uint256 collateralPrice = COLLATERAL_PRICE.mulDiv(200, 100);
        setCollateralPrice(collateralPrice);
        setCollateralPoolPrice(collateralPrice.mulDiv(100_000, 98_999));
        vm.expectRevert(Errors.leftoverLoanTokens());
        vault.harvest(type(uint256).max);
    }

    function test_harvest_smallSwapLimit() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));
        uint256 debtBefore = vault.debt();
        uint256 collateralBefore = vault.collateral();

        setYieldPrice(YIELD_PRICE * 10);
        vault.harvest(1e4);
        vault.harvest(10e4);

        uint256 yieldAfter = YIELD_TOKEN.balanceOf(address(vault));
        assertEq(yieldAfter + 11e4, yieldBefore);
        assertEq(vault.debt(), debtBefore);
        assertGt(vault.collateral(), collateralBefore);
    }

    function test_harvest_largeAount() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 yieldBefore = YIELD_TOKEN.balanceOf(address(vault));
        uint256 debtBefore = vault.debt();
        uint256 collateralBefore = vault.collateral();

        setYieldPrice(YIELD_PRICE * 1000);
        vault.harvest(type(uint256).max);

        uint256 yieldAfter = YIELD_TOKEN.balanceOf(address(vault));
        assertEq(yieldAfter * 1000, yieldBefore);
        assertEq(vault.debt(), debtBefore);
        assertGt(vault.collateral(), collateralBefore);
    }

    function testFuzz_harvest_liquidationRecoveryDoesNotRevert(uint256 seizedCollateral, uint256 repaidAssets) public {
        seizedCollateral = uint256(bound(seizedCollateral, 1e4, 1 ether));
        repaidAssets = uint256(bound(repaidAssets, 1e4, 1 ether));

        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        MORPHO.liquidate(vault.market(), address(vault), seizedCollateral, repaidAssets);

        vault.harvest(type(uint256).max);
        vault.rebalance();

        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertGe(redeemed, (1 ether - seizedCollateral).mulDiv(999, 1000));
    }

    function test_harvest_noopBelowYieldDebt() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE.mulDiv(99, 100));
        vault.harvest(type(uint256).max);
        assertEq(vault.collateral(), 1 ether);

        setYieldPrice(YIELD_PRICE.mulDiv(1, 1000));
        vault.harvest(type(uint256).max);
        assertEq(vault.collateral(), 1 ether);
    }

    function test_harvest_harvestsTinySurplusAboveYieldToLoanMax() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE.mulDiv(1 + 1e6, 1e6));
        vault.harvest(type(uint256).max);
        assertGt(vault.collateral(), 1 ether);
    }

    function test_harvest_revertsWhenEmergencyRecoveryActive() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();

        vm.expectRevert(Errors.emergencyRecoveryActive());
        vault.harvest(type(uint256).max);
    }

    function test_harvest_revertsWhenEmergencyRecoveryExecuted() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.expectRevert(Errors.emergencyRecoveryActive());
        vault.harvest(type(uint256).max);
    }

    function test_harvest_zeroYieldIsNoOp() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE * 2);
        vault.harvest(0);
        assertEq(vault.collateral(), 1 ether);
    }

    function test_harvest_CollateralDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE * 2);
        deal(address(COLLATERAL_TOKEN), address(vault), 10 ether);

        vault.harvest(type(uint256).max);
        assertEq(COLLATERAL_TOKEN.balanceOf(address(vault)), 10 ether);
    }

    function test_harvest_LoanDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE * 2);
        deal(address(LOAN_TOKEN), address(vault), 10 ether);

        vault.harvest(type(uint256).max);
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 10 ether);
    }
}
