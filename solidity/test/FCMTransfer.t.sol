// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

contract FCMTransferTest is Test, Deployers {
    using SafeERC20 for FCMVault;
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
    }

    function test_transfer_noEarlyAccessReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.expectRevert(Errors.noEarlyAccess(stranger));
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer) expect different revert
        vault.transfer(stranger, shares);
    }

    function test_transfer_earlyAccessSenderReceiver() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.grantEarlyAccess(bob);

        vm.prank(alice);
        vault.safeTransfer(bob, shares);
    }

    function test_transfer_noEarlyAccessSender() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.revokeEarlyAccess(alice);
        vm.prank(owner);
        vault.grantEarlyAccess(bob);

        vm.expectRevert(Errors.noEarlyAccess(alice));
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer) expect different revert
        vault.transfer(bob, shares);
    }
}
