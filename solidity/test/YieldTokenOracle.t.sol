// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {YieldTokenOracle} from "../src/YieldTokenOracle.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Morpho's ORACLE_PRICE_SCALE.
uint256 constant ORACLE_PRICE_SCALE = 1e36;

/// @dev Default conversion sample: large enough that the vault's convertToAssets floor is ~1e-18 relative, so it stays
/// negligible for any realistic position size.
uint256 constant DEFAULT_CONVERSION_SAMPLE = 1e36;

/// @dev Mirrors how Morpho values a position from an `IOracle` price: `assets = shares.mulDivDown(price,
/// ORACLE_PRICE_SCALE)`. Running the oracle output through this strips the 1e36 scaling, so the tests can assert
/// against amounts in the asset's native units rather than scaled prices.
function convertSharesToAssets(uint256 shares, uint256 price) pure returns (uint256) {
    return Math.mulDiv(shares, price, ORACLE_PRICE_SCALE);
}

contract YieldTokenOracleTest is Test {
    address internal constant ASSET = address(0xBBB2);

    MockERC4626 internal vault;

    function setUp() public {
        vault = new MockERC4626(ASSET, 18);
    }

    function _oracle() internal returns (YieldTokenOracle) {
        return new YieldTokenOracle(IERC4626(address(vault)), ASSET, DEFAULT_CONVERSION_SAMPLE);
    }

    function test_priceAtParity() public {
        // 18-decimal shares, 6-decimal asset, rate 1:1 => one whole share
        // (1e18) redeems for one whole asset (1e6).
        vault.setRate(1e6);
        assertEq(convertSharesToAssets(1e18, _oracle().price()), 1e6, "1:1 rate, 18->6 decimals");
        assertEq(convertSharesToAssets(2e18, _oracle().price()), 2e6, "1:1 rate, 18->6 decimals");
    }

    function test_priceTracksExchangeRate() public {
        vault.setRate(1.05e6);
        assertEq(convertSharesToAssets(1e18, _oracle().price()), 1.05e6, "rate above parity");
        assertEq(convertSharesToAssets(2e18, _oracle().price()), 2.1e6, "rate above parity");

        vault.setRate(0.97e6);
        assertEq(convertSharesToAssets(1e18, _oracle().price()), 0.97e6, "rate below parity");
        assertEq(convertSharesToAssets(2e18, _oracle().price()), 1.94e6, "rate below parity");
    }

    function test_priceWithEqualDecimals() public {
        vault = new MockERC4626(ASSET, 6);
        vault.setRate(2e6);
        // 6-decimal shares and asset: one whole share (1e6) redeems for two
        // whole assets (2e6) at a 2x rate.
        assertEq(convertSharesToAssets(1e6, _oracle().price()), 2e6, "equal decimals, 2x rate");
        assertEq(convertSharesToAssets(2e6, _oracle().price()), 4e6, "equal decimals, 2x rate");
    }

    function test_constructorRejectsAssetMismatch() public {
        vm.expectRevert(YieldTokenOracle.AssetMismatch.selector);
        new YieldTokenOracle(IERC4626(address(vault)), address(0xDEAD), DEFAULT_CONVERSION_SAMPLE);
    }

    function test_constructorRejectsZeroConversionSample() public {
        vm.expectRevert(YieldTokenOracle.ZeroConversionSample.selector);
        new YieldTokenOracle(IERC4626(address(vault)), ASSET, 0);
    }

    /// @dev With a `1e36` conversion sample, the accumulated floor when pricing a large position is bounded by
    /// `heldShares / sample`. For a ~$1M position (`1e24` raw shares) that bound is `1e-12` raw asset wei, which rounds
    /// to zero in both an 18-share/6-asset vault (the deployed FUSDEV/PYUSD0 shape) and an 18-share/18-asset vault --
    /// so the 18/6 config prices as precisely as the 18/18 config.
    function test_conversionSampleBoundsPricingError() public {
        uint256 oneShare = 1e18;
        uint256 heldShares = 1e24; // 1,000,000 whole shares (~$1M at 1:1).
        uint256 sample = DEFAULT_CONVERSION_SAMPLE;
        uint256 errorBound = heldShares / sample; // 1e24 / 1e36 = 0 raw wei.

        // 18/6: per-share value 1_000_000.999... raw, floors to 1_000_000.
        MockERC4626 inner6 = new MockERC4626(ASSET, 6);
        inner6.setFractionalRate(1_000_001 * oneShare - 1, oneShare * oneShare);
        // 18/18: per-share value 1e18 + 0.999... raw, floors to 1e18.
        MockERC4626 inner18 = new MockERC4626(ASSET, 18);
        inner18.setFractionalRate(oneShare * oneShare + oneShare - 1, oneShare * oneShare);

        YieldTokenOracle oracle6 = new YieldTokenOracle(IERC4626(address(inner6)), ASSET, sample);
        YieldTokenOracle oracle18 = new YieldTokenOracle(IERC4626(address(inner18)), ASSET, sample);

        uint256 error6 = inner6.convertToAssets(heldShares) - convertSharesToAssets(heldShares, oracle6.price());
        uint256 error18 = inner18.convertToAssets(heldShares) - convertSharesToAssets(heldShares, oracle18.price());

        assertLe(error6, errorBound, "18/6 error within H/S bound");
        assertLe(error18, errorBound, "18/18 error within H/S bound");
    }
}
