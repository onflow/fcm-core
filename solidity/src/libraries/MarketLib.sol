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

    function accrueInterest(MarketParams memory market) internal {
        MORPHO.accrueInterest(market);
    }

    function supplyCollateral(MarketParams memory market, uint256 assets) internal {
        MORPHO.supplyCollateral(market, assets, address(this), "");
    }

    function borrow(MarketParams memory market, uint256 assets) internal {
        MORPHO.borrow(market, assets, 0, address(this), address(this));
    }

    // ---- reads ---------------------------------------------------------

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

    function collateralToDebt(MarketParams memory market, uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        if (collateralAmount == 0) return 0;
        return collateralAmount.mulDiv(oraclePrice(market), ORACLE_PRICE_SCALE);
    }

    function debtToCollateral(MarketParams memory market, uint256 debtAmount)
        internal
        view
        returns (uint256)
    {
        if (debtAmount == 0) return 0;
        return debtAmount.mulDiv(ORACLE_PRICE_SCALE, oraclePrice(market));
    }

    function maxBorrowFor(MarketParams memory market, uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        return collateralToDebt(market, collateralAmount).mulDiv(market.lltv, WAD);
    }

    function maxBorrow(MarketParams memory market) internal view returns (uint256) {
        return maxBorrowFor(market, collateral(market));
    }

    function healthFactor(MarketParams memory market) internal view returns (uint256) {
        uint256 debtAmount = debt(market);
        if (debtAmount == 0) return type(uint256).max;
        return maxBorrow(market).mulDiv(WAD, debtAmount);
    }

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
