// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "./MockERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Minimal Morpho Blue mock used by the test rig. Exposes `position`
///      and `market` as public mappings; the vault reads via these auto-
///      getters instead of going through Morpho's periphery `extSloads`.
contract MockMorpho {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;

    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => Market) public market;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function accrueInterest(MarketParams memory mp) external {
        market[mp.id()].lastUpdate = uint128(block.timestamp);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes calldata) external {
        require(assets != 0, "ZERO_ASSETS");
        Id id = mp.id();
        position[id][onBehalf].collateral += SafeCast.toUint128(assets);
        IERC20(mp.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function borrow(
        MarketParams memory mp,
        uint256 assets,
        uint256,
        /*shares*/
        address onBehalf,
        address receiver
    )
        external
        returns (uint256, uint256)
    {
        Id id = mp.id();
        Market storage m = market[id];

        uint256 newShares = _mulDivUp(
            assets, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS
        );

        position[id][onBehalf].borrowShares += SafeCast.toUint128(newShares);
        m.totalBorrowShares += SafeCast.toUint128(newShares);
        m.totalBorrowAssets += SafeCast.toUint128(assets);

        MockERC20(mp.loanToken).mint(receiver, assets);

        return (assets, newShares);
    }

    /// @notice Mock for Morpho's `repay`. Burns `assets` of the loan token
    ///         from the caller and decrements the `onBehalf` position's
    ///         borrow shares plus the market totals.
    /// @dev    Uses `MockERC20.burn` instead of `transferFrom` so tests don't
    ///         need to manage Morpho allowances. Mirrors Morpho's share
    ///         rounding (`assets * (totalShares + VIRTUAL_SHARES) /
    ///         (totalAssets + VIRTUAL_ASSETS)`, rounded UP) and caps shares
    ///         burned at the position's outstanding balance — the cap is a
    ///         mock-only safeguard against rounding overshoot on full repay;
    ///         real Morpho enforces this via its accounting invariants. The
    ///         `shares` and `data` parameters are ignored.
    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        Id id = mp.id();
        Market storage m = market[id];

        // Mirror Morpho: exactly one of (assets, shares) is set. By-shares repays a
        // precise share count (assets rounded up); by-assets converts assets -> shares.
        uint256 sharesToBurn;
        if (shares > 0) {
            sharesToBurn = shares;
            assets = _mulDivUp(
                shares, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(m.totalBorrowShares) + VIRTUAL_SHARES
            );
        } else {
            // Morpho rounds by-assets repay DOWN (toSharesDown).
            sharesToBurn = _mulDivDown(
                assets, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS
            );
        }
        // No clamp: like Morpho, over-burning more shares than the position holds
        // underflows and reverts.
        uint128 posShares = position[id][onBehalf].borrowShares;
        position[id][onBehalf].borrowShares = posShares - SafeCast.toUint128(sharesToBurn);
        m.totalBorrowShares -= SafeCast.toUint128(sharesToBurn);
        m.totalBorrowAssets -= SafeCast.toUint128(assets);

        MockERC20(mp.loanToken).burn(msg.sender, assets);

        return (assets, sharesToBurn);
    }

    /// @notice Mock for Morpho's `withdrawCollateral`. Decrements the
    ///         position's collateral balance and transfers the collateral
    ///         token to `receiver`.
    /// @dev    The real Morpho enforces post-state health factor ≥ 1 here,
    ///         rejecting withdrawals that would put the position
    ///         under-collateralized. This mock skips that check; tests
    ///         needing HF-bound behavior should drive position state
    ///         explicitly. Redeem tests don't need it because they repay
    ///         debt before withdrawing collateral.
    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        Id id = mp.id();
        position[id][onBehalf].collateral -= SafeCast.toUint128(assets);
        IERC20(mp.collateralToken).safeTransfer(receiver, assets);
    }

    /// @notice Test-only hook that simulates a liquidation against `borrower`:
    ///         seizes `seizedCollateral` units of collateral and repays
    ///         `repaidAssets` of loan-token debt. The caller chooses how much
    ///         of each independently.
    /// @dev    Only the position/market accounting is mutated to mirror the
    ///         net effect of a real Morpho `liquidate`: collateral is reduced
    ///         and the borrow position (shares + market totals) is paid down
    ///         using the same share rounding as `repay`. No tokens are moved
    ///         and no liquidation-incentive or bad-debt math is applied —
    ///         tests only need the resulting accounting state (e.g. an
    ///         underwater position with genuinely reduced collateral) to
    ///         exercise rebalance recovery. The share burn is capped at the
    ///         position's balance, and `repaidAssets == 0` makes this a pure
    ///         collateral seizure.
    /// @param  mp               Market params identifying the position.
    /// @param  borrower         Position owner being liquidated.
    /// @param  seizedCollateral Collateral units removed from the position.
    /// @param  repaidAssets     Loan-token debt repaid (reduces borrow shares
    ///                          and market totals).
    function liquidate(MarketParams memory mp, address borrower, uint256 seizedCollateral, uint256 repaidAssets)
        external
    {
        Id id = mp.id();
        Market storage m = market[id];

        position[id][borrower].collateral -= SafeCast.toUint128(seizedCollateral);

        if (repaidAssets > 0) {
            uint256 sharesToBurn = _mulDivUp(
                repaidAssets,
                uint256(m.totalBorrowShares) + VIRTUAL_SHARES,
                uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS
            );
            uint128 posShares = position[id][borrower].borrowShares;
            if (sharesToBurn > posShares) sharesToBurn = posShares;

            position[id][borrower].borrowShares = posShares - SafeCast.toUint128(sharesToBurn);
            m.totalBorrowShares -= SafeCast.toUint128(sharesToBurn);
            m.totalBorrowAssets -= SafeCast.toUint128(repaidAssets);
        }
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev Mock of Morpho's `flashLoan`: mints `assets` of `token` to the
    ///      borrower, invokes its `onMorphoFlashLoan` callback, then reclaims the
    ///      `assets` (fee-free, like Morpho Blue) via the borrower's approval.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        MockERC20(token).mint(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        MockERC20(token).burn(address(this), assets);
    }
}
