// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMNotImplementedTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    bytes errorNotImplemented = Errors.notImplemented();

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(1 ether);
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
        vault.grantFundApprove(alice, 1 ether);
    }

    function test_notImplemented_previewDepositReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.previewDeposit(1 ether);
    }

    function test_notImplemented_maxMintZero() public view {
        assertEq(vault.maxMint(alice), 0);
    }

    function test_notImplemented_previewMintReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.previewMint(1 ether);
    }

    function test_notImplemented_mintReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.mint(1, alice);
    }

    function test_notImplemented_maxWithdrawZero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_notImplemented_previewWithdrawReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.previewWithdraw(1 ether);
    }

    function test_notImplemented_withdrawReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.withdraw(1 ether, alice, alice);
    }

    function test_notImplemented_previewRedeemReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.previewRedeem(1 ether);
    }
}
