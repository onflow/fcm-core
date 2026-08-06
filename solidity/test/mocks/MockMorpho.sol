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
    /// @notice Test-only cap on total outstanding debt for a market,
    ///         0 = uncapped. See `setBorrowCap`.
    mapping(Id => uint256) public borrowCap;
    /// @notice Test-only floor on a position's collateral, 0 = unconstrained.
    ///         See `setMinCollateral`.
    mapping(Id => mapping(address => uint256)) public minCollateral;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Test-only setter that caps how much a market can ever have
    ///         borrowed in total (`Market.totalBorrowAssets`), mirroring a
    ///         market with limited lender supply. Left at the zero default,
    ///         `borrow` is uncapped, so every pre-existing test that never
    ///         calls this keeps its previous unconstrained behavior.
    function setBorrowCap(MarketParams memory mp, uint256 cap) external {
        borrowCap[mp.id()] = cap;
    }

    /// @notice Test-only setter that stops `withdrawCollateral` from taking
    ///         `borrower`'s collateral below `floor` for this market,
    ///         mirroring "Morpho blocks a withdrawal that would leave the
    ///         position underwater" without deriving it from real LTV/oracle
    ///         math -- the test decides directly when a position is blocked
    ///         (set a floor) and when it's healthy again (set it back to 0).
    ///         Left at the zero default, `withdrawCollateral` is
    ///         unconstrained, so every pre-existing test that never calls
    ///         this keeps its previous behavior.
    function setMinCollateral(MarketParams memory mp, address borrower, uint256 floor) external {
        minCollateral[mp.id()][borrower] = floor;
    }

    function accrueInterest(MarketParams memory mp) external {
        market[mp.id()].lastUpdate = uint128(block.timestamp);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes calldata) external {
        require(assets != 0, "ZERO_ASSETS");
        Id id = mp.id();
        position[id][onBehalf].collateral += SafeCast.toUint128(assets);
        IERC20(mp.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @dev Mirrors a market with limited lender supply: a borrow that would
    ///      push `totalBorrowAssets` past `borrowCap` reverts
    ///      `INSUFFICIENT_LIQUIDITY`. The check is opt-in — skipped entirely
    ///      while `borrowCap == 0` (the untouched default), so every
    ///      pre-existing test that never calls `setBorrowCap` keeps its
    ///      previous unconstrained behavior.
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

        uint256 cap = borrowCap[id];
        if (cap > 0) {
            require(uint256(m.totalBorrowAssets) + assets <= cap, "INSUFFICIENT_LIQUIDITY");
        }

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
    ///         burned at the position's outstanding balance - the cap is a
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
    /// @dev    Reverts if the withdrawal would take the position below its
    ///         `minCollateral` floor (opt-in, see `setMinCollateral`); 0 is
    ///         always satisfied, so every pre-existing test that never sets a
    ///         floor keeps its previous unconstrained behavior.
    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        Id id = mp.id();
        // position[id][onBehalf].collateral -= SafeCast.toUint128(assets);
        // IERC20(mp.collateralToken).safeTransfer(receiver, assets);
        Position storage pos = position[id][onBehalf];
        uint256 newCollateral = uint256(pos.collateral) - assets;

        require(newCollateral >= minCollateral[id][onBehalf], "INSUFFICIENT_COLLATERAL");

        pos.collateral = SafeCast.toUint128(newCollateral);
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
    ///         and no liquidation-incentive or bad-debt math is applied -
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

    /// @dev Mock of Morpho's `flashLoan`: lends `assets` of `token` from the
    ///      singleton's OWN balance to the borrower, invokes its `onMorphoFlashLoan`
    ///      callback, then reclaims the `assets` (fee-free, like Morpho Blue) via the
    ///      borrower's approval. Lending from the real balance rather than minting is
    ///      deliberate: it makes the flash depend on the singleton actually holding
    ///      the token, so a flash of a token the singleton custodies none of — e.g.
    ///      the loan token, which the vault only ever borrows — reverts, exactly as
    ///      on-chain. This is what lets a test prove redeem's Case-B flash is
    ///      self-collateralized (draws only on supplied collateral, not idle loan).
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        MockERC20(token).burn(address(this), assets);
    }
}
