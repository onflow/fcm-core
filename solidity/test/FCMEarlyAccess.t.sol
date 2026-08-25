// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

contract FCMEarlyAccessTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();

        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        COLLATERAL_TOKEN.mint(alice, 1 ether);
        vm.prank(alice);
        COLLATERAL_TOKEN.approve(address(vault), 1 ether);
    }

    function test_earlyAccess_defaultNoEarlyAccess() public view {
        assertFalse(vault.earlyAccess(alice));
        assertFalse(vault.earlyAccess(bob));
        assertFalse(vault.earlyAccess(carol));
        assertFalse(vault.earlyAccess(stranger));
    }

    function test_earlyAccess_onlyOwnerCanGrant() public {
        vm.expectRevert(Errors.ownableUnauthorizedAccount(stranger));
        vm.prank(stranger);
        vault.grantEarlyAccess(stranger);
    }

    function test_earlyAccess_grantEarlyAccess() public {
        vm.prank(owner);
        vault.grantEarlyAccess(alice);
        assertTrue(vault.earlyAccess(alice));

        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_earlyAccess_grantEarlyAccessTwice() public {
        vm.prank(owner);
        vault.grantEarlyAccess(alice);
        assertTrue(vault.earlyAccess(alice));
        vm.prank(owner);
        vault.grantEarlyAccess(alice);
        assertTrue(vault.earlyAccess(alice));

        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_earlyAccess_revokeEarlyAccess() public {
        vm.prank(owner);
        vault.grantEarlyAccess(alice);
        assertTrue(vault.earlyAccess(alice));
        vm.prank(owner);
        vault.revokeEarlyAccess(alice);
        assertFalse(vault.earlyAccess(alice));

        vm.expectRevert(Errors.noEarlyAccess(alice));
        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_earlyAccess_revokeEarlyAccessTwice() public {
        vm.prank(owner);
        vault.revokeEarlyAccess(alice);
        assertFalse(vault.earlyAccess(alice));
        vm.prank(owner);
        vault.revokeEarlyAccess(alice);
        assertFalse(vault.earlyAccess(alice));

        vm.expectRevert(Errors.noEarlyAccess(alice));
        vm.prank(alice);
        vault.deposit(1 ether, alice);
    }

    function test_earlyAccess_emitsEventsOnGrantAndRevoke() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.EarlyAccessGranted(alice);
        vault.grantEarlyAccess(alice);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.EarlyAccessRevoked(alice);
        vault.revokeEarlyAccess(alice);
    }
}
