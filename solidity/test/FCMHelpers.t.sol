// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {MorphoLib} from "../src/libraries/MorphoLib.sol";
import {Deployers} from "./utils/Deployers.sol";
import {IMorpho, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Dedicated coverage for `FCMHelpers`. The library's entire reason for existing is to read the vault's own
/// Morpho position (`address(vault)`) rather than the caller's (`address(this)`), so it is safe to call from a test
/// contract that holds no Morpho position. The `*_readsVaultPositionNotCaller` tests pin that property directly: they
/// would fail if any reader regressed to `MorphoLib`'s two-arg (caller-based) form.
contract FCMHelpersTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using Math for uint256;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        grantFundApprove(alice, 1 ether);
    }

    function test_market_returnsVaultImmutables() public view {
        MarketParams memory mp = vault.market();
        assertEq(mp.loanToken, address(vault.LOAN_TOKEN()));
        assertEq(mp.collateralToken, address(vault.COLLATERAL_TOKEN()));
        assertEq(mp.oracle, address(vault.MARKET_ORACLE()));
        assertEq(mp.irm, address(vault.MARKET_IRM()));
        assertEq(mp.lltv, vault.MARKET_LLTV());
    }

    function test_debt_zeroBeforeAnyBorrow() public view {
        assertEq(vault.debt(), 0);
    }

    function test_debt_readsVaultPositionNotCaller() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        // The caller (this test contract) holds no Morpho position, so the `address(this)`-based `MorphoLib.debt`
        // reads 0 — the exact regression `FCMHelpers.debt` exists to avoid.
        assertEq(vault.MORPHO().debt(vault.market()), 0);
        assertGt(vault.debt(), 0);
        // FCMHelpers.debt must equal a direct user-overload read of the vault's position.
        assertEq(vault.debt(), vault.MORPHO().debt(vault.market(), address(vault)));
    }

    function test_debt_matchesShareToAssetConversion() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        // Reproduce Morpho's borrow-share -> asset conversion (Ceil, virtual shares/assets) and confirm FCMHelpers
        // agrees to the wei, locking the math against the live market state.
        Position memory pos = vault.position();
        Market memory mkt = vault.MORPHO().market(vault.market().id());
        uint256 expectedDebt = pos.borrowShares == 0
            ? 0
            : uint256(pos.borrowShares)
                .mulDiv(uint256(mkt.totalBorrowAssets) + 1, uint256(mkt.totalBorrowShares) + 1e6, Math.Rounding.Ceil);
        assertEq(vault.debt(), expectedDebt);
    }

    function test_collateral_readsVaultPositionNotCaller() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertEq(vault.MORPHO().collateral(vault.market()), 0); // caller holds none
        assertEq(vault.collateral(), 1 ether); // the vault supplied the deposited collateral to Morpho
        assertEq(vault.collateral(), vault.MORPHO().collateral(vault.market(), address(vault)));
    }

    function test_yield_matchesYieldTokenBalance() public {
        assertEq(vault.yield(), 0);

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        assertEq(vault.yield(), YIELD_TOKEN.balanceOf(address(vault)));
        assertGt(vault.yield(), 0);
    }

    function test_position_matchesCollateralAndBorrowShares() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        Position memory pos = vault.position();
        assertEq(pos.collateral, vault.collateral());
        assertGt(pos.borrowShares, 0);
    }

    function test_healthFactor_maxWhenNoDebt() public view {
        assertEq(vault.healthFactor(), type(uint256).max);
    }

    function test_healthFactor_readsVaultPositionAfterDeposit() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        // A deposit targets the band midpoint of the re-entry targets.
        uint256 midpoint = (HEALTH_FACTOR_MAX_TARGET + HEALTH_FACTOR_MIN_TARGET) / 2;
        assertEq(vault.healthFactor(), midpoint);
        assertGe(vault.healthFactor(), HEALTH_FACTOR_MIN);
        assertLe(vault.healthFactor(), HEALTH_FACTOR_MAX);

        // Caller has no debt -> the `address(this)`-based `MorphoLib.healthFactor` stays at max; the vault's does not.
        assertEq(vault.MORPHO().healthFactor(vault.market()), type(uint256).max);
        assertLt(vault.healthFactor(), type(uint256).max);
        assertEq(vault.healthFactor(), vault.MORPHO().healthFactor(vault.market(), address(vault)));
    }

    function test_healthFactor_tracksCollateralPrice() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 hfAtDeposit = vault.healthFactor();

        // Debt is unaffected by the oracle price (the mock accrues no interest), so the health factor moves purely
        // with the max-borrowable amount — over-levered when collateral cheapens, under-levered when it appreciates.
        setCollateralPrice(COLLATERAL_PRICE / 2);
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);
        assertLt(vault.healthFactor(), hfAtDeposit);

        setCollateralPrice(COLLATERAL_PRICE * 2);
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MAX);
        assertGt(vault.healthFactor(), hfAtDeposit);
    }
}
