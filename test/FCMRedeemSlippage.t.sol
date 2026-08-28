// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

contract FCMRedeemSlippageTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    uint256 internal fairAssets;
    uint256 internal aliceShares;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);
        grantFundApprove(alice, 3 ether);

        vm.prank(alice);
        aliceShares = vault.deposit(2 ether, alice);
        vm.prank(alice);
        fairAssets = vault.redeem(aliceShares / 2, alice, alice);
    }

    function test_redeemSlippage_succeedsWithExactMinAssetsOut() public {
        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares / 2, alice, alice, fairAssets);
        assertEq(assets, fairAssets);
    }

    function test_redeemSlippage_revertsWhenMinAssetsOutExceeded() public {
        vm.expectRevert(Errors.slippageExceeded(fairAssets, fairAssets + 1));
        vm.prank(alice);
        vault.redeem(aliceShares / 2, alice, alice, fairAssets + 1);
    }

    function test_redeemSlippage_zeroMinAssetsOutSucceeds() public {
        vm.prank(alice);
        vault.redeem(aliceShares / 2, alice, alice, 0);
    }
}
