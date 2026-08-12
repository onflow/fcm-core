// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {FeesLib} from "../src/libraries/FeesLib.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Tests for FeesLib.feesToMint — verifies fee calculation and logical
/// branches in isolation. Event emission is tested via the vault integration tests.
contract FeesLibTest is Test {
    using Math for uint256;

    function setUp() public {
        vm.warp(0);
    }

    function test_FeesToMint_ZeroBeforeElapsed() public view {
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 200,
            performanceFeeBps: 1000,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(shares, 0);
    }

    function test_FeesToMint_ZeroWhenNavIsZero() public {
        skip(1000);
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 0,
            claims: 100e18,
            managementFeeBps: 200,
            performanceFeeBps: 1000,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(shares, 0);
    }

    function test_FeesToMint_ZeroWhenMgmtAndPerfAreZero() public {
        skip(1000);
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 0,
            performanceFeeBps: 0,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(shares, 0);
    }

    function test_FeesToMint_ManagementFeeOnly() public {
        skip(365 days);
        (uint256 managementFee,, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 100,
            performanceFeeBps: 0,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 1e18);
        assertApproxEqRel(shares, uint256(100e18) / 99, 1);
    }

    function test_FeesToMint_PerformanceFeeOnlyNoGain() public view {
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 0,
            performanceFeeBps: 100,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(shares, 0);
    }

    function test_FeesToMint_PerformanceFeeOnlyWithGain() public view {
        (, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 110e18,
            claims: 100e18,
            managementFeeBps: 0,
            performanceFeeBps: 1000,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(performanceFee, 1e18);
        assertApproxEqRel(shares, uint256(100e18) / 109, 1);
    }

    function test_FeesToMint_BothFeeTypes() public {
        skip(365 days);
        (uint256 managementFee, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 110e18,
            claims: 100e18,
            managementFeeBps: 100,
            performanceFeeBps: 1000,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 1.1e18);
        assertEq(performanceFee, 1e18);
        // Exact formula: 2.1e18 * 100e18 / 107.9e18 = 2100e18 / 1079
        assertApproxEqRel(shares, uint256(2100e18) / 1079, 1);
    }

    function test_FeesToMintMax() public {
        skip(365 days);
        (uint256 managementFee, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 1000,
            performanceFeeBps: 5000,
            perfHighWaterMark: 0,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 10e18);
        assertEq(performanceFee, 50e18);
        assertApproxEqRel(shares, uint256(600e18) / 4, 1);
    }

    function test_FeesToMintBiggerNav_ManagementFeeOnly() public {
        skip(365 days);
        // mgmt fee (101.101e18) exceeds nav (101e18) -> hits the unreachable
        // `feeAssets > nav` branch, which must zero all three returns.
        (uint256 managementFee, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 101e18,
            claims: 100e18,
            managementFeeBps: 10_001,
            performanceFeeBps: 0,
            perfHighWaterMark: 1e18,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 0, "managementFee zeroed");
        assertEq(performanceFee, 0, "performanceFee zeroed");
        assertEq(shares, 0, "feeShares zeroed");
    }

    function test_FeesToMintBiggerNav_PerformanceFeeOnly() public view {
        // perf fee (100.01e18) exceeds nav (100e18) -> hits the unreachable
        // `feeAssets > nav` branch, which must zero all three returns.
        (uint256 managementFee, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 100e18,
            claims: 100e18,
            managementFeeBps: 0,
            performanceFeeBps: 10_001,
            perfHighWaterMark: 0,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 0, "managementFee zeroed");
        assertEq(performanceFee, 0, "performanceFee zeroed");
        assertEq(shares, 0, "feeShares zeroed");
    }

    function test_FeesToMintBiggerNav_PerformanceFeeOnly_730days() public view {
        (uint256 managementFee, uint256 performanceFee, uint256 shares) = FeesLib.feesToMint({
            nav: 1e18,
            claims: 100e18,
            managementFeeBps: 0,
            performanceFeeBps: 1001,
            perfHighWaterMark: 0.9e18,
            lastFeeAccrual: 0
        });
        assertEq(managementFee, 0);
        assertEq(performanceFee, 0);
        assertEq(shares, 0);
    }

    function test_FeesToMint_ManagementFeeOnly_730days() public {
        skip(730 days);
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 2e18,
            claims: 100e18,
            managementFeeBps: 5001,
            performanceFeeBps: 0,
            perfHighWaterMark: 0,
            lastFeeAccrual: 0
        });
        assertApproxEqRel(shares, uint256(100e18).mulDiv(5001, 4999), 1);
    }

    function test_FeesToMint_Compounding() public {
        uint256 claims = 100e18;
        uint256 nav = 100e18;
        uint256 lastFeeAccrual = 0;
        for (uint256 i = 0; i < 365 * 24; i++) {
            skip(1 hours);
            (,, uint256 shares) = FeesLib.feesToMint({
                nav: nav,
                claims: claims,
                managementFeeBps: 1000,
                performanceFeeBps: 0,
                perfHighWaterMark: 0,
                lastFeeAccrual: lastFeeAccrual
            });
            lastFeeAccrual += 1 hours;
            claims += shares;
        }
        assertApproxEqRel(claims, 110.5e18, 0.001e18);
        uint256 userNav = nav.mulDiv(100e18, claims);
        assertApproxEqRel(userNav, 90.5e18, 0.001e18);
    }

    // with 100$ in the protocol fees will accrue after 10 seconds.
    // with 1s of elapsed time, rounding errors will lead to no fees.
    // 100$ and 10 seconds is well within reasonable bounds.
    function test_FeesToMint_USDC() public {
        skip(10);
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: 100e6,
            claims: 100e12,
            managementFeeBps: 1000,
            performanceFeeBps: 0,
            perfHighWaterMark: 0,
            lastFeeAccrual: 0
        });
        assertGt(shares, 0);
    }

    function testFuzz_FeesToMint_UnreachableNeverHit(
        uint256 nav,
        uint256 claims,
        uint16 managementFeeBps,
        uint16 performanceFeeBps,
        uint256 perfHighWaterMark,
        uint256 elapsed
    ) public {
        // 1. Bound inputs to realistic protocol limits
        nav = bound(nav, 1e12, 100_000_000e18);
        claims = bound(claims, 1e12, 100_000_000e18);

        // Bound fees to your vault's MAX allowed BPS caps
        managementFeeBps = uint16(bound(managementFeeBps, 1, 1000)); // Max 10%
        performanceFeeBps = uint16(bound(performanceFeeBps, 1, 5000)); // Max 50%

        uint256 pricePerShare = nav.mulDiv(MarketLib.WAD, claims);
        perfHighWaterMark = bound(perfHighWaterMark, 0, pricePerShare);

        elapsed = bound(elapsed, 1, 366 days);
        skip(elapsed);

        // 2. Execute call - if feeAssets > nav, assert(false) will panic and fail the test
        (,, uint256 shares) = FeesLib.feesToMint({
            nav: nav,
            claims: claims,
            managementFeeBps: managementFeeBps,
            performanceFeeBps: performanceFeeBps,
            perfHighWaterMark: perfHighWaterMark,
            lastFeeAccrual: 0
        });

        // maximum shares that can be minted is 150% of the claims
        // this equals 60% of the nav
        assertLe(shares, claims.mulDiv(15, 10));
        assertGe(shares, 1);
    }
}
