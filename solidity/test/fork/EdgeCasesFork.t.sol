// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {ForkDeployers} from "./ForkDeployers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RedeemForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;

    uint256 constant DEPOSIT_AMOUNT = 0.01e8;

    address internal repayer = makeAddr("repayer");
    address internal holder = makeAddr("user0");

    function setUp() public {
        _forkSetup();
        _fundArb();
    }

    function test_redeemFork_noDebt() public {
        setCollateralPrice(ORACLE_PRICE);
        _depositUsers(1, DEPOSIT_AMOUNT);
        _arbPoolToSpot();

        uint256 shares = vault.balanceOf(holder);

        _externalRepayFullDebt();
        assertEq(vault.debt(), 0);

        vm.prank(holder);
        uint256 assetsOut = vault.redeem(shares, holder, holder);

        assertGt(assetsOut, 0);
        assertEq(vault.balanceOf(holder), 0);
    }

    function test_redeemFork_noCollateral() public {
        setCollateralPrice(ORACLE_PRICE);
        _depositUsers(1, DEPOSIT_AMOUNT);
        _arbPoolToSpot();

        uint256 shares = vault.balanceOf(holder);

        _externalRepayFullDebt();
        uint256 coll = vault.collateral();
        vm.prank(address(vault));
        MORPHO.withdrawCollateral(mp, coll, address(vault), repayer);
        assertEq(vault.collateral(), 0);

        vm.prank(holder);
        uint256 assetsOut = vault.redeem(shares, holder, holder);

        assertGt(assetsOut, 0);
        assertEq(vault.balanceOf(holder), 0);
    }

    function test_redeemFork_noYield() public {
        // The collateral oracle is mocked (ORACLE_PRICE ~350x the real WBTC/PYUSD pool),
        // which would book debt the pool can't absorb when the redeem must sell collateral
        // for the full debt (no yield). Match the oracle to the pool's spot price first, so
        // debt books at a rate the collateral->loan swap can actually fill.
        (uint160 collSpot,,,,,,) = IUniswapV3Pool(collateralLoanPool).slot0();
        uint256 priceRaw = Math.mulDiv(uint256(collSpot), uint256(collSpot), 1 << 192);
        setCollateralPrice(priceRaw * 1e36);

        _depositUsers(1, DEPOSIT_AMOUNT);
        _arbPoolToSpot();

        uint256 shares = vault.balanceOf(holder);
        deal(address(FUSDEV), address(vault), 0);
        assertEq(FUSDEV.balanceOf(address(vault)), 0);

        vm.prank(holder);
        uint256 assetsOut = vault.redeem(shares, holder, holder);

        assertGt(assetsOut, 0);
        assertEq(vault.balanceOf(holder), 0);
    }

    function _externalRepayFullDebt() internal {
        uint256 borrowShares = uint256(vault.position().borrowShares);
        deal(address(PYUSD0), repayer, vault.debt() * 2 + 1e6);

        vm.startPrank(repayer);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(mp, 0, borrowShares, address(vault), "");
        vm.stopPrank();
    }
}
