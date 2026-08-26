// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MorphoLib
/// @author Flow Foundation
/// @notice Helpers around a Morpho Blue market.
library MorphoLib {
    using Math for uint256;
    using MarketParamsLib for MarketParams;

    /// @notice Repay the entire borrow position, by shares, so the debt is zeroed exactly.
    function repayAll(IMorpho morpho, MarketParams memory market, address user)
        internal
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        uint256 borrowedShares = morpho.position(market.id(), user).borrowShares;
        return morpho.repay(market, 0, borrowedShares, user, "");
    }

    /// @notice Returns `user`'s collateral balance in the given market, in raw collateral-token units.
    function collateral(IMorpho morpho, MarketParams memory market, address user) internal view returns (uint256) {
        return morpho.position(market.id(), user).collateral;
    }

    /// @notice Returns `user`'s current debt in the given Morpho market, denominated in raw loan-token units.
    function debt(IMorpho morpho, MarketParams memory market, address user) internal view returns (uint256) {
        uint256 borrowShares_ = borrowShares(morpho, market, user);
        if (borrowShares_ == 0) return 0;
        Market memory mkt = morpho.market(market.id());
        return SharesMathLib.toAssetsUp(borrowShares_, uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));
    }

    /// @notice Returns `user`'s current borrow shares in the given Morpho market.
    function borrowShares(IMorpho morpho, MarketParams memory market, address user) internal view returns (uint256) {
        return morpho.position(market.id(), user).borrowShares;
    }

    /// @notice Returns the loan-token amount corresponding to `borrowShares_` in the given Morpho market.
    function borrowSharesToAssets(IMorpho morpho, MarketParams memory market, uint256 borrowShares_)
        internal
        view
        returns (uint256)
    {
        Market memory mkt = morpho.market(market.id());
        return SharesMathLib.toAssetsUp(borrowShares_, uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));
    }
}
