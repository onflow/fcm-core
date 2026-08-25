// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {ForkDeployers} from "./ForkDeployers.sol";
import {console} from "forge-std/console.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RedeemForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;
    using SafeERC20 for IERC20;
    using Math for uint256;

    function setUp() public {
        setupFork();
        grantFundApprove(alice, 1 ether);
    }

    function test_edgeCaseFork_noDebt() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);

        _externalRepayFullDebt();
        assertEq(vault.debt(), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertGt(assetsOut, 1.5e6);
    }

    function test_edgeCaseFork_noCollateral() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);

        _externalRepayFullDebt();
        uint256 coll = vault.collateral();
        vm.prank(address(vault));
        MORPHO.withdrawCollateral(_market(), coll, address(vault), address(1));
        assertEq(vault.collateral(), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertGt(assetsOut, 0.6e6);
        assertLt(assetsOut, 0.8e6);
    }

    function test_edgeCaseFork_noYield() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);
        // setCollateralPrice(COLLATERAL_PRICE.mulDiv(200, 100));

        uint256 balance = FUSDEV.balanceOf(address(vault));
        vm.prank(address(vault));
        FUSDEV.safeTransfer(bob, balance);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertGt(assetsOut, 0.1e6);
        assertLt(assetsOut, 0.5e6);
    }

    function test_edgeCaseFork_highCollateralPrice() public {
        uint256 expectedAssets = _expectedAssetsOut(100);
        setCollateralPrice(2e40);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(100, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, expectedAssets, 2);
    }

    function test_edgeCaseFork_lowCollateralPrice() public {
        uint256 expectedAssets = _expectedAssetsOut(100);
        console.log("expectedAssets", expectedAssets);
        setCollateralPrice(COLLATERAL_PRICE);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(100, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, expectedAssets, 2);
    }

    function test_edgeCaseFork_highYieldPrice() public {
        uint256 expectedAssets = _expectedAssetsOut(1e6);
        setYieldPrice(2e46);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1e6, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, expectedAssets, 2);
    }

    function test_edgeCaseFork_lowYieldPrice() public {
        uint256 expectedAssets = _expectedAssetsOut(1e6);
        setYieldPrice(1);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(1e6, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, expectedAssets, 2);
    }

    function _expectedAssetsOut(uint256 assetsIn) internal returns (uint256) {
        uint256 snapshotId = vm.snapshot();
        vm.startPrank(alice);
        uint256 shares = vault.deposit(assetsIn, alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        vm.revertToState(snapshotId);
        return assetsOut;
    }

    function _externalRepayFullDebt() internal {
        uint256 borrowShares = uint256(vault.position().borrowShares);
        vm.startPrank(arbitrager);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(_market(), 0, borrowShares, address(vault), "");
        vm.stopPrank();
    }
}
