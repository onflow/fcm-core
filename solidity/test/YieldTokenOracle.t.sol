// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {YieldTokenOracle} from "../src/YieldTokenOracle.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @dev Morpho's ORACLE_PRICE_SCALE.
uint256 constant ORACLE_PRICE_SCALE = 1e36;

/// @dev Mirrors how Morpho values a position from an `IOracle` price:
///      `assets = shares.mulDivDown(price, ORACLE_PRICE_SCALE)`. Running the
///      oracle output through this strips the 1e36 scaling, so the tests can
///      assert against amounts in the asset's native units rather than
///      scaled prices.
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
        return new YieldTokenOracle(IERC4626(address(vault)), ASSET);
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
        new YieldTokenOracle(IERC4626(address(vault)), address(0xDEAD));
    }
}
