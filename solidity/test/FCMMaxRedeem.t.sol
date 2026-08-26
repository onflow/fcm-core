// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMMaxRedeemTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        grantFundApprove(bob, 1 ether);
    }

    /// @dev Redeem deliberately stays open while a recovery is only pending, so `maxRedeem` must too.
    function test_maxRedeem_unchangedWhilePendingEmergencyRecovery() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.scheduleEmergencyRecovery();

        assertEq(vault.maxRedeem(alice), shares, "pending recovery does not close the exit");
    }

    function test_maxRedeem_zeroAfterExecutedEmergencyRecovery() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        LOAN_TOKEN.mint(owner, 1e10 ether);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 0, vault.position().borrowShares, address(vault), "");
        vault.executeEmergencyRecovery();
        vm.stopPrank();

        assertGt(vault.balanceOf(alice), 0, "alice still holds shares");
        assertEq(vault.maxRedeem(alice), 0, "but maxRedeem reports zero, matching redeem's revert");

        vm.expectRevert(Errors.emergencyRecoveryActive());
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    function test_maxRedeem_zeroWhenNoBalance() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_returnsBalanceWhenHealthy() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_maxRedeem_zeroWhenUnhealthy() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertGt(shares, 0);

        setCollateralPrice(COLLATERAL_PRICE / 2);
        assertGt(vault.ltv(), LTV_MAX);

        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_veryHealthy() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertGt(shares, 0);

        setCollateralPrice(COLLATERAL_PRICE * 10);
        assertLt(vault.ltv(), LTV_MIN);

        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_maxRedeem_perOwnerIndependence() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1 ether, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(0.5 ether, bob);

        assertEq(vault.maxRedeem(alice), aliceShares);
        assertEq(vault.maxRedeem(bob), bobShares);
        assertEq(vault.maxRedeem(stranger), 0);
    }

    function test_redeem_unhealthyAndNoYield() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setYieldPrice(1);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(80, 100));

        assertGt(vault.ltv(), LTV_MAX);
        assertLt(vault.ltv(), MARKET_LLTV);
        assertGt(vault.totalAssets(), 0);

        assertEq(vault.maxRedeem(alice), 0);
        deal(address(YIELD_TOKEN), address(vault), 0);
        assertEq(vault.maxRedeem(alice), shares);
    }
}
