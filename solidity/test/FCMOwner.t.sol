// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMOwnerTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    bytes errorOwnerUnauthorized = Errors.ownableUnauthorizedAccount(address(owner));

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
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
}
