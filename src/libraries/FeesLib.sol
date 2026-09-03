// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BPS, LTV_SCALE} from "./ConstantsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeesLib
/// @author Flow Foundation
/// @notice Fee maths for the FCMVault.
library FeesLib {
    using Math for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @notice Calculates the fee shares to mint for the given parameters.
    /// @dev Pure calculation; the caller mints the shares and emits `FeesAccrued`.
    /// @param nav Net asset value, in collateral-token units.
    /// @param claims Total supply plus the virtual shares from the decimals offset.
    /// @param managementFeeBps Annual management fee rate.
    /// @param performanceFeeBps Performance fee rate on gains above the high-water mark.
    /// @param perfHighWaterMark All-time peak price-per-share, 1e18-scaled.
    /// @param lastFeeAccrual Timestamp the management fee was last billed to.
    /// @return managementFee Management fee for this accrual, in asset terms.
    /// @return performanceFee Performance fee for this accrual, in asset terms.
    /// @return feeShares Shares to mint to the fee recipient.
    function feesToMint(
        uint256 nav,
        uint256 claims,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        uint256 perfHighWaterMark,
        uint256 lastFeeAccrual
    ) external view returns (uint256 managementFee, uint256 performanceFee, uint256 feeShares) {
        uint256 pricePerShare = nav.mulDiv(LTV_SCALE, claims);

        // Accrual is irregular (every interaction, plus permissionless `accrueFees`), so bill `rate * elapsed`.
        // Capping the gap at a year forgives longer idle stretches, which holds the realized drag at or below the
        // nominal annual rate and bounds a single catch-up dilution after dormancy.
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        // forge-lint: disable-next-line(block-timestamp)
        if (elapsed > SECONDS_PER_YEAR) elapsed = SECONDS_PER_YEAR;

        // forge-lint: disable-next-line(block-timestamp)
        if (managementFeeBps > 0 && elapsed > 0) {
            managementFee = nav.mulDiv(managementFeeBps * elapsed, BPS * SECONDS_PER_YEAR);
        }

        if (performanceFeeBps > 0 && pricePerShare > perfHighWaterMark) {
            // pps is unrealized and oracle-marked, so a transient mark can crystallize a fee on paper profit - kept,
            // not refunded. The strict all-time HWM is what stops the same gain being charged twice.
            uint256 gain = (pricePerShare - perfHighWaterMark).mulDiv(claims, LTV_SCALE);
            performanceFee = gain.mulDiv(performanceFeeBps, BPS);
        }

        uint256 feeAssets = managementFee + performanceFee;
        if (feeAssets > 0) {
            // Unreachable under the vault's fee caps; skipping beats reverting every entry point that accrues.
            if (feeAssets > nav) return (0, 0, 0);
            // Dilution: price the mint at the post-fee NAV. `+1` mirrors the virtual asset in the share conversion.
            uint256 navAfterFee = nav + 1 - feeAssets;
            feeShares = feeAssets.mulDiv(claims, navAfterFee);
        }
        return (managementFee, performanceFee, feeShares);
    }
}
