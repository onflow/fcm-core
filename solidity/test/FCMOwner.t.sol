// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests for FCMVault ownership transfer (Ownable2Step).
contract FCMOwnerTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    bytes errorOwnerUnauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(owner));

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
    }

    function test_TransferOwnershipTransfersControl() public {
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
