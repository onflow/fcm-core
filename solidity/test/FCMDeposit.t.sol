// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Test} from "forge-std/Test.sol";

contract FCMDepositTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    bytes errorActive = abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
        vault.grantFundApprove(bob, 1 ether);
    }

    function test_DepositBlockedDuringEmergencyRecovery() public {
        vm.startPrank(owner);
        vault.grantEarlyAccess(alice);
        vault.setMaxTvl(1 ether);
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

    function test_DepositBlockedAfterEmergencyRecovery() public {
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

    function test_DepositLimitBelowLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        uint256 shares = vault.deposit(500, alice);
        assertGt(shares, 0);
    }

    function test_DepositLimitExactlyAtLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);
    }

    function test_DepositLimitOneOverLimitReverts() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1001, 1000));
        vault.deposit(1001, alice);
    }

    function test_DepositLimitIsGlobalAcrossUsers() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);

        vm.prank(alice);
        vault.deposit(600, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 500, 400));
        vault.deposit(500, bob);

        vm.prank(bob);
        vault.deposit(400, bob);
    }

    function test_RevertsWhenTvlLimitLoweredBelowTvl() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(800, alice);

        vm.prank(owner);
        vault.setMaxTvl(500);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1, 0));
        vault.deposit(1, alice);
    }

    function test_TracksLimitChanges() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vm.prank(alice);
        vault.deposit(1000, alice);

        vm.prank(owner);
        vault.setMaxTvl(2500);
        vm.prank(alice);
        vault.deposit(1500, alice);
    }
}
