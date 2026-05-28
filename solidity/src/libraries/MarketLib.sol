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

    function supplyCollateral(
        MarketParams memory market,
        uint256 assets
    ) internal {
        MORPHO.supplyCollateral(market, assets, address(this), "");
    }

    function borrow(MarketParams memory market, uint256 assets) internal {
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
    function repay(
        MarketParams memory market,
        uint256 assets
    ) internal returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        return MORPHO.repay(market, assets, 0, address(this), "");
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
    function withdrawCollateral(
        MarketParams memory market,
        uint256 assets
    ) internal {
        MORPHO.withdrawCollateral(market, assets, address(this), address(this));
    }

    // ---- reads ---------------------------------------------------------

    function collateral(
        MarketParams memory market
    ) internal view returns (uint256) {
        return uint256(MORPHO.position(market.id(), address(this)).collateral);
    }

    function debt(MarketParams memory market) internal view returns (uint256) {
        Position memory pos = MORPHO.position(market.id(), address(this));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MORPHO.market(market.id());
        return
            uint256(pos.borrowShares).mulDiv(
                uint256(mkt.totalBorrowAssets) + VIRTUAL_ASSETS,
                uint256(mkt.totalBorrowShares) + VIRTUAL_SHARES,
                Math.Rounding.Ceil
            );
    }

    function oraclePrice(
        MarketParams memory market
    ) internal view returns (uint256) {
        return IOracle(market.oracle).price();
    }

    function collateralToDebt(
        MarketParams memory market,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        if (collateralAmount == 0) return 0;
        return collateralAmount.mulDiv(oraclePrice(market), ORACLE_PRICE_SCALE);
    }

    function debtToCollateral(
        MarketParams memory market,
        uint256 debtAmount
    ) internal view returns (uint256) {
        if (debtAmount == 0) return 0;
        return debtAmount.mulDiv(ORACLE_PRICE_SCALE, oraclePrice(market));
    }

    function maxBorrowFor(
        MarketParams memory market,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        return
            collateralToDebt(market, collateralAmount).mulDiv(market.lltv, WAD);
    }

    function maxBorrow(
        MarketParams memory market
    ) internal view returns (uint256) {
        return maxBorrowFor(market, collateral(market));
    }

    function healthFactor(
        MarketParams memory market
    ) internal view returns (uint256) {
        uint256 debtAmount = debt(market);
        if (debtAmount == 0) return type(uint256).max;
        return maxBorrow(market).mulDiv(WAD, debtAmount);
    }

    function maxBorrowAtHf(
        MarketParams memory market,
        uint256 targetHf
    ) internal view returns (uint256) {
        uint256 targetDebt = maxBorrow(market).mulDiv(WAD, targetHf);
        uint256 currentDebt = debt(market);
        return targetDebt > currentDebt ? targetDebt - currentDebt : 0;
    }
}
