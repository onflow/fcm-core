// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "../../interfaces/IFCMVault.sol";
import "../ConstantsLib.sol";
import {MorphoLib} from "../MorphoLib.sol";
import {IMorpho, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title FCMHelpers
/// @author Flow Foundation
/// @notice Read-only views over an `IFCMVault`'s Morpho position, safe to call from a context that is not the vault
/// itself (e.g. a test contract). Each reader delegates to the `address`-overload of its `MorphoLib` counterpart,
/// passing `address(vault)` so the position read is the vault's, not the caller's (`address(this)`).
library FCMHelpers {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using Math for uint256;

    function market(IFCMVault vault) internal view returns (MarketParams memory _market) {
        _market.loanToken = address(vault.LOAN_TOKEN());
        _market.collateralToken = address(vault.COLLATERAL_TOKEN());
        _market.oracle = address(vault.COLLATERAL_ORACLE());
        _market.irm = address(vault.MARKET_IRM());
        _market.lltv = vault.MARKET_LLTV();
    }

    /// @dev The vault's outstanding debt in its Morpho market, in raw loan-token units. Delegates to
    /// `MorphoLib.debt(morpho, market, address(vault))`.
    function debt(IFCMVault vault) internal view returns (uint256) {
        return vault.MORPHO().debt(market(vault), address(vault));
    }

    function debtInCollateralAssets(IFCMVault vault) internal view returns (uint256) {
        return debt(vault).mulDiv(ORACLE_PRICE_SCALE, vault.COLLATERAL_ORACLE().price());
    }

    /// @dev The vault's collateral supplied to its Morpho market, in raw collateral-token units. Delegates to
    /// `MorphoLib.collateral(morpho, market, address(vault))`.
    function collateral(IFCMVault vault) internal view returns (uint256) {
        return vault.MORPHO().collateral(market(vault), address(vault));
    }

    function yield(IFCMVault vault) internal view returns (uint256) {
        return vault.YIELD_TOKEN().balanceOf(address(vault));
    }

    /// @dev The vault's Morpho position (collateral + borrow shares).
    function position(IFCMVault vault) internal view returns (Position memory) {
        return vault.MORPHO().position(market(vault).id(), address(vault));
    }

    /// @notice Current LTV of the vault's Morpho position (1e18-scaled).
    /// @dev Returns 0 when the position is empty, `type(uint256).max` when debt remains but collateral is gone.
    /// @param vault The vault whose LTV is being read.
    function ltv(IFCMVault vault) internal view returns (uint256) {
        uint256 coll = collateral(vault);
        if (coll == 0) return debt(vault) == 0 ? 0 : type(uint256).max;
        return debtInCollateralAssets(vault).mulDiv(LTV_SCALE, coll);
    }
}
