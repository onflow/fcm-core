// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title YieldTokenOracle
/// @notice Prices ERC4626 vault shares in terms of the vault's underlying
///         asset, derived from the vault's own exchange rate, following
///         Morpho's `IOracle` convention: `price()` returns the asset value
///         of 1e36 base units of the share token, so
///         `assetAmount = shareAmount * price() / 1e36` (in each token's
///         native base units -- the vault's conversion already embeds both
///         tokens' decimals, so no explicit decimal scaling is required).
///
///         NAV-based pricing cannot be moved by trading against a pool, so
///         it needs no TWAP; it is only as trustworthy as the vault's own
///         share accounting. It reflects redemption value, not the price a
///         swap on a secondary market will execute at -- arbitrage keeps the
///         two close while vault redemptions remain permissionless.
contract YieldTokenOracle is IOracle {
    /// @dev Morpho's ORACLE_PRICE_SCALE.
    uint256 internal constant PRICE_SCALE = 1e36;

    IERC4626 public immutable yieldToken;
    address public immutable loanToken;

    /// @dev One whole yield token, used as the conversion sample so the
    ///      vault's rounding error stays negligible.
    uint256 public immutable conversionSample;

    error AssetMismatch();

    constructor(IERC4626 yieldToken_, address loanToken_) {
        if (yieldToken_.asset() != loanToken_) revert AssetMismatch();
        yieldToken = yieldToken_;
        loanToken = loanToken_;
        conversionSample = 10 ** yieldToken_.decimals();
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        return
            Math.mulDiv(yieldToken.convertToAssets(conversionSample), PRICE_SCALE, conversionSample);
    }
}
