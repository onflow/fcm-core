// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title YieldTokenOracle
/// @author Flow Foundation
/// @notice Prices ERC4626 vault shares in terms of the vault's underlying asset, derived from the vault's own exchange
/// rate, following Morpho's `IOracle` convention: `price()` returns the asset value of 1e36 base units of the share
/// token, so `assetAmount = shareAmount * price() / 1e36` (in each token's native base units - the vault's conversion
/// already embeds both tokens' decimals, so no explicit decimal scaling is required).
contract YieldTokenOracle is IOracle {
    /// @dev Morpho's ORACLE_PRICE_SCALE.
    uint256 internal constant PRICE_SCALE = 1e36;

    /// @notice The ERC4626 yield vault whose shares are being priced.
    IERC4626 public immutable VAULT;

    /// @notice The vault's underlying asset, i.e. the token prices are quoted in.
    address public immutable ASSET;

    /// @notice Share amount `price()` converts, to spread `convertToAssets`'s rounding floor over many shares.
    uint256 public immutable CONVERSION_SAMPLE;

    error AssetMismatch();
    error ZeroAddress();
    error ZeroConversionSample();

    /// @param asset The vault's underlying asset; must match `vault.asset()`.
    /// @param conversionSample Too small understates large holdings, because `convertToAssets(1)` floors away most of
    /// the precision on a share worth more than one unit of its asset. Too large overflows inside the vault.
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
