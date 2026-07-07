// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams, Position, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MORPHO} from "../FCMVault.sol";

/// @title MarketLib
/// @notice Read + write helpers around a Morpho Blue market on Flow EVM
///         mainnet. Hardcodes the Morpho singleton so callers operate purely
///         on a `MarketParams`. All prices follow Morpho's IOracle convention
///         (1e36-scaled collateral→debt).
///
///         Callers MUST call `accrueInterest` in the same tx before reading
///         `debt` — this lib reads `position` + `market` directly instead of
///         going through Morpho's `expectedBorrowAssets` periphery.
library MarketLib {
    using Math for uint256;
    using MarketParamsLib for MarketParams;

    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    // ---- writes --------------------------------------------------------

    /// @notice Settles accrued interest on the given market into Morpho's stored state.
    /// @dev Must be called in the same tx before any read that depends on up-to-the-block
    /// debt (e.g. `debt`, `healthFactor`, `maxBorrowAtHealthFactor`). Without this, reads
    /// reflect the last-touched block's state.
    function accrueInterest(MarketParams memory market) internal {
        MORPHO.accrueInterest(market);
    }

    /// @notice Supplies `assets` of collateral token from this contract to the market on behalf of itself.
    /// @dev Assumes the caller has already approved the Morpho singleton for `assets` of the
    /// collateral token.
    function supplyCollateral(MarketParams memory market, uint256 assets) internal {
        MORPHO.supplyCollateral(market, assets, address(this), "");
    }

    /// @notice Borrows `assets` of loan token against this contract's collateral, with the loan tokens sent to itself.
    /// @dev Passes `shares = 0` so Morpho interprets the call as an asset-denominated borrow.
    /// Reverts inside Morpho if the resulting position would exceed LLTV.
    function borrow(MarketParams memory market, uint256 assets) internal {
        // asset-denominated borrow (shares=0); returned share/asset counts aren't needed
        // slither-disable-next-line unused-return
        MORPHO.borrow(market, assets, 0, address(this), address(this));
    }

    /// @notice Repay `assets` units of the loan token to Morpho, reducing
    ///         this contract's debt on the market.
    ///
    /// @dev   `onBehalf = address(this)` repays this contract's own
    ///         position; the trailing `""` is Morpho's callback data, unused.
    /// @param  market  Morpho market parameters identifying the position.
    /// @param  assets  Amount of loan token to repay, in token units.
    /// @return assetsRepaid Mirrors `assets` (Morpho's return convention).
    /// @return sharesRepaid Borrow shares burned by this repayment.
    function repay(MarketParams memory market, uint256 assets)
        internal
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        // return is forwarded but no caller consumes it; repay reverts on failure
        // slither-disable-next-line unused-return
        return MORPHO.repay(market, assets, 0, address(this), "");
    }

    /// @notice Repay the entire borrow position, by shares, so the debt is
    ///         zeroed exactly.
    /// @dev    Repaying by assets can't zero the position exactly: shares are far
    ///         finer-grained than assets, so converting an asset amount back to
    ///         shares either over-shoots (repaying `debt()` over-burns -> revert)
    ///         or under-shoots (leaving dust borrow shares that block a
    ///         full-collateral withdrawal). Repaying by shares clears it precisely.
    ///         Morpho pulls the required loan token from this contract's balance,
    ///         so the caller must pre-fund it.
    /// @return assetsRepaid Loan token consumed to clear the position.
    function repayAll(MarketParams memory market) internal returns (uint256 assetsRepaid) {
        uint256 borrowShares = uint256(MORPHO.position(market.id(), address(this)).borrowShares);
        if (borrowShares == 0) return 0;
        // sharesRepaid intentionally dropped; only assetsRepaid is needed
        // slither-disable-next-line unused-return
        (assetsRepaid,) = MORPHO.repay(market, 0, borrowShares, address(this), "");
    }

    /// @notice Withdraw `assets` units of the collateral token from this
    ///         contract's Morpho position back to this contract.
    /// @dev    Morpho enforces that the withdrawal leaves the position with
    ///         a health factor ≥ 1.
    ///
    ///         Both the `onBehalf` and `receiver` arguments to Morpho are
    ///         `address(this)`: the collateral belongs to this contract.
    /// @param  market  Morpho market parameters identifying the position.
    /// @param  assets  Amount of collateral to withdraw, in token units.
    function withdrawCollateral(MarketParams memory market, uint256 assets) internal {
        MORPHO.withdrawCollateral(market, assets, address(this), address(this));
    }

    // ---- reads ---------------------------------------------------------

    /// @notice Returns this contract's collateral balance in the given market, in raw collateral-token units.
    function collateral(MarketParams memory market) internal view returns (uint256) {
        return uint256(MORPHO.position(market.id(), address(this)).collateral);
    }

    /// @notice Returns this contract's current debt in the given Morpho market, denominated in raw loan-token units.
    /// @dev `pos.borrowShares` represents the "debt shares" we owe. Debt shares are an intermediary
    /// representation used to track each borrower's proportional claim on the market's total debt as
    /// interest accrues over time.
    ///
    /// `mkt.totalBorrowShares` is the total outstanding "debt shares" across all borrowers, and
    /// `mkt.totalBorrowAssets` is the total outstanding debt denominated in the loan asset. Our debt
    /// in asset terms is therefore `(borrowShares / totalBorrowShares) * totalBorrowAssets`.
    ///
    /// For example, if `borrowShares` is 10 and `totalBorrowShares` is 100, we owe 10% of all debt
    /// in the market. If `totalBorrowAssets` is 1000, we owe (10/100) * 1000 = 100 units of the loan
    /// asset.
    ///
    /// `VIRTUAL_ASSETS` and `VIRTUAL_SHARES` are Morpho's inflation-attack mitigation: they seed the
    /// share/asset ratio so the first borrower cannot manipulate it. They must be included in every
    /// conversion to match Morpho's internal accounting.
    ///
    /// CAUTION: Call `accrueInterest(market)` first if an up-to-the-block value is required.
    function debt(MarketParams memory market) internal view returns (uint256) {
        Position memory pos = MORPHO.position(market.id(), address(this));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MORPHO.market(market.id());
        return uint256(pos.borrowShares)
            .mulDiv(
                uint256(mkt.totalBorrowAssets) + VIRTUAL_ASSETS,
                uint256(mkt.totalBorrowShares) + VIRTUAL_SHARES,
                Math.Rounding.Ceil
            );
    }

    /// @notice Returns the price of 1 unit of collateral token quoted in loan token, scaled by 1e36.
    /// @dev The returned price has `36 + loanDecimals - collateralDecimals` decimals of precision, so that
    /// `collateralAmount * price / 1e36` yields the collateral's value in raw loan-token units regardless
    /// of the two tokens' decimal configurations.
    ///
    /// Example (WETH collateral / USDC loan, 1 WETH = 2500 USDC):
    ///   price = 2500 * 10^(36 + 6 - 18) = 2.5e27
    ///   1 WETH (1e18) collateral → (1e18 * 2.5e27) / 1e36 = 2.5e9 = 2500 USDC
    function oraclePrice(MarketParams memory market) internal view returns (uint256) {
        return IOracle(market.oracle).price();
    }

    /// @notice Converts a collateral amount to its value in loan-token units at the current oracle price.
    /// @dev Does not apply LLTV; this is a raw value conversion. Use `maxBorrowFor` for the
    /// LLTV-discounted borrowable amount.
    function collateralToDebt(MarketParams memory market, uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        if (collateralAmount == 0) return 0;
        return collateralAmount.mulDiv(oraclePrice(market), ORACLE_PRICE_SCALE);
    }

    /// @notice Converts a loan-token amount to its equivalent collateral-token amount at the current oracle price.
    /// @dev Inverse of `collateralToDebt`. Does not apply LLTV.
    function debtToCollateral(MarketParams memory market, uint256 debtAmount)
        internal
        view
        returns (uint256)
    {
        if (debtAmount == 0) return 0;
        return debtAmount.mulDiv(ORACLE_PRICE_SCALE, oraclePrice(market));
    }

    /// @notice Returns the maximum loan-token amount borrowable against `collateralAmount` at the market's LLTV.
    /// @dev Equal to `collateralToDebt(collateralAmount) * lltv / WAD`. A position at exactly
    /// this debt level has a health factor of WAD (the liquidation threshold).
    function maxBorrowFor(MarketParams memory market, uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        return collateralToDebt(market, collateralAmount).mulDiv(market.lltv, WAD);
    }

    /// @notice Returns the maximum loan-token amount borrowable against this contract's current collateral balance.
    /// @dev Convenience wrapper over `maxBorrowFor(collateral(market))`.
    function maxBorrow(MarketParams memory market) internal view returns (uint256) {
        return maxBorrowFor(market, collateral(market));
    }

    /// @notice Returns this contract's health factor in the given market, scaled by WAD (1e18).
    /// @dev The health factor is the ratio of the maximum borrowable amount (at the current
    /// collateral balance and LLTV) to the current debt. A value of WAD means the position is
    /// exactly at the liquidation threshold; values below WAD are liquidatable, values above
    /// are healthy. Returns `type(uint256).max` when there is no debt, since an unborrowed
    /// position cannot be liquidated.
    ///
    /// CAUTION: Call `accrueInterest(market)` first if an up-to-the-block value is required,
    /// since `debt` reads stored state and does not include unaccrued interest.
    function healthFactor(MarketParams memory market) internal view returns (uint256) {
        uint256 debtAmount = debt(market);
        if (debtAmount == 0) return type(uint256).max;
        return maxBorrow(market).mulDiv(WAD, debtAmount);
    }

    /// @notice Returns the additional loan-token amount this contract can borrow to reach `targetHealthFactor`.
    /// @dev `targetHealthFactor` is WAD-scaled (WAD = liquidation threshold). Returns 0 if the
    /// current debt already implies a health factor at or below the target (i.e. borrowing more
    /// would push the position deeper toward liquidation than requested).
    ///
    /// CAUTION: Call `accrueInterest(market)` first if an up-to-the-block value is required.
    function maxBorrowAtHealthFactor(MarketParams memory market, uint256 targetHealthFactor)
        internal
        view
        returns (uint256)
    {
        uint256 targetDebt = maxBorrow(market).mulDiv(WAD, targetHealthFactor);
        uint256 currentDebt = debt(market);
        return targetDebt > currentDebt ? targetDebt - currentDebt : 0;
    }
}
