// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMIntegrationTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        vm.prank(alice);
        vault.approve(address(vault), type(uint256).max);
        grantFundApprove(bob, 1 ether);
        vm.prank(bob);
        vault.approve(address(vault), type(uint256).max);

        MORPHO.supplyLiquidity(vault.market(), 1 ether);
    }

    function test_integration_roundTripChangingCollateralPrice() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(200, 100));
        vault.rebalance();

        setCollateralPrice(COLLATERAL_PRICE);
        vault.rebalance();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertApproxEqAbs(COLLATERAL_TOKEN.balanceOf(address(alice)), 1 ether, 2);
    }

    function test_integration_roundTripReturnsDeposited() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertEq(COLLATERAL_TOKEN.balanceOf(alice), assetsOut);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_integration_recoveryAfterLiquidation() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 yield = YIELD_TOKEN.balanceOf(address(vault));
        console.log("yield", yield);

        MORPHO.liquidate(vault.market(), address(vault), 0.5 ether, 1000 ether);

        vault.harvest(type(uint256).max);
        vault.rebalance();

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
    }

    function test_integration_harvestThenLeversWhenSurplusLarge() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(100);

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        YIELD_TOKEN.mint(address(vault), YIELD_TOKEN.balanceOf(address(vault)) / 2);

        uint256 collBefore = vault.collateral();
        uint256 debtBefore = vault.debt();

        vault.harvest(type(uint256).max);
        vault.rebalance();

        assertGt(vault.collateral(), collBefore);
        assertGt(vault.debt(), debtBefore);
        assertApproxEqRel(vault.ltv(), LTV_MIN_TARGET, 1e15);
    }

    function test_integration_rebalanceUnblocksRedeem() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(100);

        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(80, 100));

        vm.expectRevert(Errors.vaultUnhealthy());
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);

        vault.rebalance();
        assertLe(vault.ltv(), LTV_MAX);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares / 2, alice, alice);
        assertGt(assetsOut, 0);
    }

    function test_integration_boundedLossAfterLiquidationRecovery() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(100);

        COLLATERAL_TOKEN.mint(alice, 9 ether);
        vm.prank(alice);
        COLLATERAL_TOKEN.approve(address(vault), 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether, alice);

        // Partial liquidation: seize 35% of collateral, no debt repaid.
        MORPHO.liquidate(vault.market(), address(vault), 3.5 ether, 0);
        assertGt(vault.ltv(), LTV_MAX);
        uint256 navAfterLiquidation = vault.totalAssets();

        vault.rebalance();
        assertLe(vault.ltv(), LTV_MAX);
        uint256 navAfterRecovery = vault.totalAssets();

        // Budget: 2% of NAV for a full liquidation, scaled to the 35% actually liquidated.
        uint256 maxExtraLossBps = 200 * 3500 / 10_000; // 0.7%
        assertGe(navAfterRecovery, navAfterLiquidation * (10_000 - maxExtraLossBps) / 10_000);
    }

    function test_integration_rebalanceZeroesSurvivingDebtAfterFullLiquidation() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(100);

        COLLATERAL_TOKEN.mint(alice, 9 ether);
        vm.prank(alice);
        COLLATERAL_TOKEN.approve(address(vault), 10 ether);
        vm.prank(alice);
        uint256 shares = vault.deposit(10 ether, alice);

        // Full liquidation: seize ALL collateral, no debt repaid.
        MORPHO.liquidate(vault.market(), address(vault), 10 ether, 0);
        assertEq(vault.collateral(), 0);
        uint256 debtBefore = vault.debt();
        assertGt(debtBefore, 0);

        // Must not revert even with no collateral to lever against.
        vault.rebalance();

        assertLt(vault.debt(), debtBefore);
        assertApproxEqAbs(vault.debt(), 0, 10 ether / 1000);
        assertEq(vault.ltv(), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertEq(assetsOut, 0);
    }

    function test_integration_highCollateralPrice() public {
        setCollateralPrice(2e46);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
    }

    function test_integration_lowCollateralPrice() public {
        setCollateralPrice(1);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
    }

    function test_integration_highYieldPrice() public {
        setYieldPrice(2e46);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
    }

    function test_integration_lowYieldPrice() public {
        setYieldPrice(1);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 1 ether, 2);
    }
}
