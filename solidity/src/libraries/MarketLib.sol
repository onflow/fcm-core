// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MarketLib
/// @author Flow Foundation
/// @notice Price and amount-conversion helpers around a Morpho Blue market's oracle. All prices follow Morpho's
/// `IOracle` convention (1e36-scaled collateral -> debt), and conversions do not apply LLTV unless stated.
library MarketLib {
    using Math for uint256;
    using MarketParamsLib for MarketParams;

    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Returns the price of 1 unit of collateral token quoted in loan token, scaled by 1e36.
    /// @dev The returned price has `36 + loanDecimals - collateralDecimals` decimals of precision, so that
    /// `collateralAmount * price / 1e36` yields the collateral's value in raw loan-token units regardless of the two
    /// tokens' decimal configurations.
    /// Example (WETH collateral / USDC loan, 1 WETH = 2500 USDC):
    /// price = 2500 * 10^(36 + 6 - 18) = 2.5e27
    /// 1 WETH (1e18) collateral -> (1e18 * 2.5e27) / 1e36 = 2.5e9 = 2500 USDC
    /// @param market Morpho market parameters identifying the position.
    function oraclePrice(MarketParams memory market) internal view returns (uint256) {
        return IOracle(market.oracle).price();
    }

    /// @notice Converts a collateral amount to its value in loan-token units at the current oracle price.
    /// @dev Does not apply LLTV; this is a raw value conversion. Use `maxBorrowFor` for the LLTV-discounted borrowable
    /// amount.
    /// @param market Morpho market parameters identifying the position.
    /// @param collateralAmount Amount of collateral to convert, in token units.
    function collateralToDebt(MarketParams memory market, uint256 collateralAmount) internal view returns (uint256) {
        if (collateralAmount == 0) return 0;
        return collateralAmount.mulDiv(oraclePrice(market), ORACLE_PRICE_SCALE);
    }

    /// @notice Converts a loan-token amount to its equivalent collateral-token amount at the current oracle price.
    /// @dev Inverse of `collateralToDebt`. Does not apply LLTV.
    /// @param market Morpho market parameters identifying the position.
    /// @param debtAmount Amount of loan token to convert, in token units.
    function debtToCollateral(MarketParams memory market, uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return 0;
        return debtAmount.mulDiv(ORACLE_PRICE_SCALE, oraclePrice(market));
    }

    /// @notice Returns the maximum loan-token amount borrowable against `collateralAmount` at the market's LLTV.
    /// @dev Equal to `collateralToDebt(collateralAmount) * lltv / WAD`. A position at exactly this debt level has a
    /// health factor of WAD (the liquidation threshold).
    /// @param market Morpho market parameters identifying the position.
    /// @param collateralAmount Amount of collateral to borrow against, in token units.
    function maxBorrowFor(MarketParams memory market, uint256 collateralAmount) internal view returns (uint256) {
        return collateralToDebt(market, collateralAmount).mulDiv(market.lltv, WAD);
    }
}
