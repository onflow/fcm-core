// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BPS} from "../FCMVault.sol";
import {IFCMVault} from "../interfaces/IFCMVault.sol";
import {MarketLib} from "./MarketLib.sol";
import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

/// @title FeesLib
/// @author Flow Foundation
/// @notice Library for calculating fees for the FCMVault.
library FeesLib {
    using Math for uint256;
    using MarketParamsLib for MarketParams;

    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @notice Calculates the fee shares to mint for the given parameters
    /// @dev This function already emits the FeesAccrued event if the fees are greater than 0.
    /// @param nav The net asset value of the vault.
    /// @param claims The claims of the vault.
    /// @param pricePerShare The price per share of the vault.
    /// @param managementFeeBps The management fee in basis points.
    /// @param performanceFeeBps The performance fee in basis points.
    /// @param perfHighWaterMark The performance high water mark.
    /// @param lastFeeAccrual The last fee accrual.
    /// @return feeShares The fee shares to mint.
    function feesToMint(
        uint256 nav,
        uint256 claims,
        uint256 pricePerShare,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        uint256 perfHighWaterMark,
        uint256 lastFeeAccrual
    ) external returns (uint256 feeShares) {
        // Bill exactly `rate * Δt` since the last accrual, then advance the clock
        // (accrual is irregular: every interaction + permissionless accrueFees).
        // The billable gap is capped at one year, so the fee is
        // provably <= the annual rate `r` (= bps/1e4) however long the vault
        // sits unaccrued - idle time past a year is forgiven, bounding a single
        // catch-up dilution after long dormancy. Within a year the realized drag
        // lies in `[1 - e^(-r), r]`: `r` at one accrual/year, `1 - e^(-r)` in the
        // continuous limit (negligible span <= ~r^2/2: ~0.02% at bps=200,
        // ~0.48% at the 1000 cap).
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed > SECONDS_PER_YEAR) elapsed = SECONDS_PER_YEAR;

        uint256 managementFee = 0;
        if (managementFeeBps > 0 && elapsed > 0) {
            managementFee = nav.mulDiv(managementFeeBps * elapsed, BPS * SECONDS_PER_YEAR);
        }

        uint256 performanceFee = 0;
        if (performanceFeeBps > 0 && pricePerShare > perfHighWaterMark) {
            // Fee on the gain in pps above the all-time HWM. pps is UNREALIZED and
            // oracle-marked, so a transient mark move can crystallize a fee on paper
            // profit that later reverses - kept, not refunded. The mint goes to the
            // recipient, not the triggerer, so a permissionless accrueFees call can't
            // pay its caller; the strict HWM charges net all-time highs only.
            uint256 gain = (pricePerShare - perfHighWaterMark).mulDiv(claims, MarketLib.WAD);
            performanceFee = gain.mulDiv(performanceFeeBps, BPS);
        }

        uint256 feeAssets = managementFee + performanceFee;
        if (feeAssets > 0 && feeAssets < nav) {
            uint256 navAfterFee = nav + 1 - feeAssets;
            // Mint shares worth `feeAssets` at the post-mint price (dilution).
            feeShares = feeAssets.mulDiv(claims, navAfterFee);
            if (feeShares > 0) {
                emit IFCMVault.FeesAccrued(managementFee, performanceFee, feeShares);
            }
        }
        return feeShares;
    }
}
