// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {MorphoLib} from "../src/libraries/MorphoLib.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {IMorpho, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib as MorphoBlueLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
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
        assertEq(mp.oracle, address(vault.COLLATERAL_ORACLE()));
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
        assertEq(vault.MORPHO().debt(vault.market(), address(this)), 0);
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

        assertEq(MorphoBlueLib.collateral(vault.MORPHO(), vault.market().id(), address(this)), 0); // caller holds none
        assertEq(vault.collateral(), 1 ether); // the vault supplied the deposited collateral to Morpho
        assertEq(vault.collateral(), MorphoBlueLib.collateral(vault.MORPHO(), vault.market().id(), address(vault)));
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

    function test_ltv_zeroWhenNoDebt() public view {
        assertEq(vault.ltv(), 0);
    }

    function test_ltv_readsVaultPositionAfterDeposit() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        // A deposit targets the band midpoint of the re-entry targets.
        uint256 midpoint = (LTV_MAX_TARGET + LTV_MIN_TARGET) / 2;
        assertApproxEqAbs(vault.ltv(), midpoint, 1);
        assertGe(vault.ltv(), LTV_MIN);
        assertLe(vault.ltv(), LTV_MAX);
    }

    function test_ltv_tracksCollateralPrice() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 ltvAtDeposit = vault.ltv();

        // Debt is unaffected by the oracle price (the mock accrues no interest), so LTV moves purely
        // with the collateral valuation — over-levered when collateral cheapens, under-levered when it appreciates.
        setCollateralPrice(COLLATERAL_PRICE / 2);
        assertGt(vault.ltv(), LTV_MAX);
        assertGt(vault.ltv(), ltvAtDeposit);

        setCollateralPrice(COLLATERAL_PRICE * 2);
        assertLt(vault.ltv(), LTV_MIN);
        assertLt(vault.ltv(), ltvAtDeposit);
    }
}
