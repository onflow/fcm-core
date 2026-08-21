// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMMaxDepositTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
        vault.grantFundApprove(bob, 1 ether);
    }

    function test_maxDeposit_returnsRemainingTvlCapacity() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        assertEq(vault.maxDeposit(alice), 1000);
        assertEq(vault.maxDeposit(bob), 1000);

        vm.prank(alice);
        vault.deposit(400, alice);
        assertEq(vault.maxDeposit(alice), 600);
        assertEq(vault.maxDeposit(bob), 600);
    }

    function test_maxDeposit_zeroWhenAtMaxTvlLimit() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_clampsToZeroTvlLimitLoweredBelowTvl() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(800, alice);

        vm.prank(owner);
        vault.setMaxTvl(500);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.totalAssets(), 800, "existing TVL should not change");
    }

    function test_maxDeposit_tracksLimitChanges() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);
        assertEq(vault.maxDeposit(alice), 0);

        vm.prank(owner);
        vault.setMaxTvl(2500);
        assertEq(vault.maxDeposit(alice), 1500);
    }

    function test_maxDeposit_zeroForNonAllowlisted() public view {
        assertEq(vault.maxDeposit(stranger), 0);
    }

    function test_maxDeposit_zeroWhenActiveEmergencyRecovery() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();

        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_zeroWhenUnderwater() public {
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setYieldPrice(YIELD_PRICE / 10);
        setCollateralPrice(COLLATERAL_PRICE / 10);
        assertEq(vault.maxDeposit(alice), 0);
    }
}
