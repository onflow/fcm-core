// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMNotImplementedTest is Test, Deployers {
    using VaultHelpers for FCMVault;
    bytes errorNotImplemented = abi.encodeWithSelector(IFCMVault.NotImplemented.selector);

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(10_000);
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
        vault.grantFundApprove(alice, 1 ether);
    }

    function test_MintReverts() public {
        vm.expectRevert(errorNotImplemented);
        vault.mint(1, alice);
    }

    function test_maxMintZero() public view {
        assertEq(vault.maxMint(alice), 0);
    }
}
