// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title YieldTokenOracle
/// @author Flow Foundation
/// @notice Prices ERC4626 vault shares in terms of the vault's underlying asset, derived from the vault's own exchange
/// rate, following Morpho's `IOracle` convention: `price()` returns the asset value of 1e36 base units of the share
/// token, so `assetAmount = shareAmount * price() / 1e36` (in each token's native base units -- the vault's conversion
/// already embeds both tokens' decimals, so no explicit decimal scaling is required).
contract YieldTokenOracle is IOracle {
    /// @dev Morpho's ORACLE_PRICE_SCALE.
    uint256 internal constant PRICE_SCALE = 1e36;

    /// @notice The FCMVault being priced.
    IERC4626 public immutable VAULT;

    /// @notice The asset being priced.
    address public immutable ASSET;

    /// @notice The sample amount of vault shares used to derive the share-to-asset price, set at construction.
    uint256 public immutable CONVERSION_SAMPLE;

    error AssetMismatch();
    error ZeroAddress();
    error ZeroConversionSample();

    /// @notice Constructs a new YieldTokenOracle.
    /// @param vault The ERC4626 vault whose shares are being priced.
    /// @param asset The vault's underlying asset; must match `vault.asset()`.
    /// @param conversionSample The sample amount of vault shares used to convert to the underlying asset. Should be
    /// chosen such that converting `conversionSample` to assets has enough precision. A larger sample spreads the
    /// vault's `convertToAssets` floor over more shares, reducing the per-share rounding error that accumulates when
    /// pricing large positions; too small a sample understates the value of large holdings. Must not be so large that
    /// `vault.convertToAssets(conversionSample)` overflows inside the vault.
    constructor(IERC4626 vault, address asset, uint256 conversionSample) {
        require(asset != address(0), ZeroAddress());
        require(conversionSample != 0, ZeroConversionSample());
        VAULT = vault;
        ASSET = asset;
        CONVERSION_SAMPLE = conversionSample;
        if (vault.asset() != asset) revert AssetMismatch();
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        return Math.mulDiv(VAULT.convertToAssets(CONVERSION_SAMPLE), PRICE_SCALE, CONVERSION_SAMPLE);
    }
}
