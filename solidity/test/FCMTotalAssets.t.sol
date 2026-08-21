// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMTotalAssetsTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        vault.grantFundApprove(alice, 1 ether);
        vault.grantFundApprove(bob, 1 ether);
    }

    function test_totalAssets_navRoundsToOriginalAssets() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertApproxEqAbs(vault.totalAssets(), 1 ether, 1);
    }
}
