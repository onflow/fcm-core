// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMMiscTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
        grantFundApprove(bob, 1 ether);
    }

    function test_misc_assetReturnsCollateralToken() public view {
        assertEq(address(vault.asset()), address(COLLATERAL_TOKEN));
    }

    function test_misc_convertToShares() public {
        uint256 shares0 = vault.convertToShares(0);
        assertEq(shares0, 0);
        uint256 shares1 = vault.convertToShares(1 ether);
        uint256 shares2 = vault.convertToShares(2 ether);
        assertApproxEqRel(shares1 * 2, shares2, 0.0001e18);
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(1 ether, alice);
        assertEq(sharesAlice, shares1);
    }

    function test_misc_convertToAssets() public {
        uint256 assets0 = vault.convertToAssets(0);
        assertEq(assets0, 0);
        uint256 assets1 = vault.convertToAssets(1 ether);
        uint256 assets2 = vault.convertToAssets(2 ether);
        assertApproxEqRel(assets1 * 2, assets2, 0.0001e18);
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(1 ether, alice);
        uint256 assetsAlice = vault.convertToAssets(sharesAlice);
        assertEq(assetsAlice, 1 ether);
    }

    function test_misc_onMorphoRepayRevertsWhenNotMorpho() public {
        vm.prank(alice);
        vm.expectRevert(Errors.unauthorized());
        vault.onMorphoRepay(0, "");
    }
}
