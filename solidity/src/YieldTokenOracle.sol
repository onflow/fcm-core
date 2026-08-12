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

    /// @notice One whole vault share, used as the conversion sample so the vault's rounding error stays negligible.
    uint256 public immutable CONVERSION_SAMPLE;

    error AssetMismatch();
    error ZeroAddress();

    constructor(IERC4626 vault_, address asset_) {
        require(asset_ != address(0), ZeroAddress());
        VAULT = vault_;
        ASSET = asset_;
        CONVERSION_SAMPLE = 10 ** vault_.decimals();
        if (vault_.asset() != asset_) revert AssetMismatch();
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        return Math.mulDiv(VAULT.convertToAssets(CONVERSION_SAMPLE), PRICE_SCALE, CONVERSION_SAMPLE);
    }
}
