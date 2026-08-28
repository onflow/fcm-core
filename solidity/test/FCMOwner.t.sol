// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

contract FCMOwnerTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    bytes errorOwnerUnauthorized = Errors.ownableUnauthorizedAccount(address(owner));

    function setUp() public {
        deployVault();
        grantFundApprove(alice, 1 ether);
    }

    function test_owner_initialOwner() public view {
        assertEq(vault.owner(), owner);
    }

    function test_owner_transferOwnershipTransfersControl() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice);

        vm.prank(owner);
        vm.expectRevert(errorOwnerUnauthorized);
        vault.setMaxTvl(1000);

        vm.prank(alice);
        vault.setMaxTvl(1000);
        assertEq(vault.maxTvl(), 1000);
    }

    /// @dev `renounceOwnership` is intentionally left inherited
    function test_owner_renounceOwnershipIsAllowedAndPermanent() public {
        vm.prank(owner);
        vault.setMaxTvl(1e21);

        vm.prank(owner);
        vault.renounceOwnership();
        assertEq(vault.owner(), address(0));

        vm.startPrank(owner);
        vm.expectRevert(errorOwnerUnauthorized);
        vault.setMaxTvl(1000);
        vm.expectRevert(errorOwnerUnauthorized);
        vault.grantEarlyAccess(bob);
        vm.expectRevert(errorOwnerUnauthorized);
        vault.scheduleEmergencyRecovery();
        vm.stopPrank();

        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        vm.prank(alice);
        assertGt(vault.redeem(shares, alice, alice), 0);
    }
}
