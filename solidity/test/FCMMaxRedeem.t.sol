// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMMaxRedeemTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        vault.grantFundApprove(alice, 1 ether);
        vault.grantFundApprove(bob, 1 ether);
    }

    function test_maxRedeem_zeroWhenActiveEmergencyRecovery() public {
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        assertEq(vault.maxRedeem(alice), 0);
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
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);

        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_veryHealthy() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertGt(shares, 0);

        setCollateralPrice(COLLATERAL_PRICE * 10);
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MIN);

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
}
