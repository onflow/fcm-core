// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "./MockERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockMorpho {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;

    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => Market) public market;
    /// @notice Test-only cap on total outstanding debt for a market, 0 = uncapped.
    mapping(Id => uint256) public borrowCap;
    /// @notice Test-only floor on a position's collateral, 0 = unconstrained.
    mapping(Id => mapping(address => uint256)) public minCollateral;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function setBorrowCap(MarketParams memory mp, uint256 cap) external {
        borrowCap[mp.id()] = cap;
    }

    function accrueInterest(MarketParams memory mp) external {
        market[mp.id()].lastUpdate = uint128(block.timestamp);
    }

    function supplyLiquidity(MarketParams memory mp, uint256 assets) external {
        MockERC20(mp.collateralToken).mint(address(this), assets);
    }

    function drainLiquidity(MarketParams memory mp, uint256 assets) external {
        MockERC20(mp.collateralToken).burn(address(this), assets);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes calldata) external {
        require(assets != 0, "ZERO_ASSETS");
        Id id = mp.id();
        position[id][onBehalf].collateral += SafeCast.toUint128(assets);
        IERC20(mp.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @dev Opt-in cap mirroring limited lender supply: reverts `INSUFFICIENT_LIQUIDITY` when a borrow would push
    /// `totalBorrowAssets` past `borrowCap`; skipped while `borrowCap == 0` (the default), so tests that never call
    /// `setBorrowCap` keep unconstrained behavior.
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

    /// @dev Uses `MockERC20.burn` instead of `transferFrom` so tests don't need to manage Morpho allowances. Mirrors
    /// Morpho's share rounding (toSharesUp) so per-share debt stays put; the `shares` and `data` parameters are
    /// ignored.
    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        Id id = mp.id();
        Market storage m = market[id];

        uint256 sharesToBurn;
        if (shares > 0) {
            sharesToBurn = shares;
            assets = _mulDivUp(
                shares, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(m.totalBorrowShares) + VIRTUAL_SHARES
            );
        } else {
            // Morpho rounds by-assets repay UP (toSharesUp), so per-share debt stays put — a DOWN-rounded mock left
            // `exposed_debt` below the true debt after a partial-fill lever, inflating `price = yieldBought/newDebt`
            // above the slippage bound in fuzz tests.
            sharesToBurn = _mulDivUp(
                assets, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS
            );
        }
        // No clamp: like Morpho, over-burning more shares than the position holds underflows and reverts.
        uint128 posShares = position[id][onBehalf].borrowShares;
        position[id][onBehalf].borrowShares = posShares - SafeCast.toUint128(sharesToBurn);
        m.totalBorrowShares -= SafeCast.toUint128(sharesToBurn);
        m.totalBorrowAssets -= SafeCast.toUint128(assets);

        MockERC20(mp.loanToken).burn(msg.sender, assets);

        return (assets, sharesToBurn);
    }

    /// @dev Reverts if the withdrawal would take the position below its opt-in `minCollateral` floor (see
    /// `setMinCollateral`); 0 is always satisfied, so tests that never set a floor keep unconstrained behavior.
    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        Id id = mp.id();
        Position storage pos = position[id][onBehalf];
        uint256 newCollateral = uint256(pos.collateral) - assets;

        require(newCollateral >= minCollateral[id][onBehalf], "INSUFFICIENT_COLLATERAL");

        pos.collateral = SafeCast.toUint128(newCollateral);
        IERC20(mp.collateralToken).safeTransfer(receiver, assets);
    }

    /// @notice Test-only hook simulating a liquidation: the caller independently chooses `seizedCollateral` and
    /// `repaidAssets`.
    /// @dev Only position/market accounting is mutated to mirror a real Morpho `liquidate` — no tokens move and no
    /// liquidation-incentive or bad-debt math is applied, since tests only need the resulting accounting state (e.g. an
    /// underwater position with reduced collateral) to exercise rebalance recovery. `repaidAssets == 0` is a pure
    /// collateral seizure.
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

    /// @dev Lends from the singleton's own balance rather than minting, so a flash of a token it doesn't custody (e.g.
    /// the loan token, which the vault only borrows) reverts exactly as on-chain — letting tests prove redeem's
    /// Case-B flash is self-collateralized (draws only on supplied collateral, not idle loan).
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        MockERC20(token).burn(address(this), assets);
    }
}
