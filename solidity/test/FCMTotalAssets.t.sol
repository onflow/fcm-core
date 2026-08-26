// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMTotalAssetsTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        grantFundApprove(bob, 1 ether);
    }

    function test_totalAssets_navRoundsToOriginalAssets() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertApproxEqAbs(vault.totalAssets(), 1 ether, 1);
    }

    function test_totalAssets_depositCollateralDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 navBefore = vault.totalAssets();
        deal(address(COLLATERAL_TOKEN), address(vault), 10 ether);
        assertEq(vault.totalAssets(), navBefore);
    }

    function test_totalAssets_depositLoanDonation() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 navBefore = vault.totalAssets();
        deal(address(LOAN_TOKEN), address(vault), 10 ether);
        assertEq(vault.totalAssets(), navBefore);
    }
}
