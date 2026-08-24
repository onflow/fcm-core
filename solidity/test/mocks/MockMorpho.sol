// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback, IMorphoRepayCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {ErrorsLib} from "@morpho-blue/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {UtilsLib} from "@morpho-blue/libraries/UtilsLib.sol";

import {MockERC20} from "./MockERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockMorpho {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;

    // Storage layout MUST mirror real Morpho (MorphoStorageLib) so the periphery
    // MorphoLib's extSload-based getters resolve to the right slots:
    //   0 owner, 1 feeRecipient, 2 position, 3 market, 4 isIrmEnabled, 5 isLltvEnabled,
    //   6 isAuthorized, 7 nonce, 8 idToMarketParams.
    address public owner;
    address public feeRecipient;
    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => Market) public market;
    mapping(address => bool) public isIrmEnabled;
    mapping(uint256 => bool) public isLltvEnabled;
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => uint256) public nonce;
    mapping(Id => MarketParams) public idToMarketParams;

    // Test-only state lives after the real slots so it never shifts them.
    /// @notice Test-only cap on total outstanding debt for a market, 0 = uncapped.
    mapping(Id => uint256) public borrowCap;
    bool public shouldRevert;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant LTV_SCALE = 1e18;

    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        res = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            bytes32 val;
            bytes32 slot = slots[i];
            assembly {
                val := sload(slot)
            }
            res[i] = val;
        }
    }

    function setBorrowCap(MarketParams memory mp, uint256 cap) external {
        borrowCap[mp.id()] = cap;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function accrueInterest(MarketParams memory mp) external {
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
        market[mp.id()].lastUpdate = uint128(block.timestamp);
    }

    function supplyLiquidity(MarketParams memory mp, uint256 assets) external {
        MockERC20(mp.collateralToken).mint(address(this), assets);
    }

    function drainLiquidity(MarketParams memory mp, uint256 assets) external {
        MockERC20(mp.collateralToken).burn(address(this), assets);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes calldata) external {
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
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
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
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

        require(_isHealthy(mp, id, onBehalf), "insufficient collateral");

        MockERC20(mp.loanToken).mint(receiver, assets);

        return (assets, newShares);
    }

    /// @dev Uses `MockERC20.burn` instead of `transferFrom` so tests don't need to manage Morpho allowances. Mirrors
    /// Morpho's share rounding (toSharesUp) so per-share debt stays put. Like real Morpho, dispatches
    /// `onMorphoRepay` after the accounting but before pulling tokens, so a caller can procure the repaid assets
    /// inside the callback (the flash-repay pattern used by redeem's Case B).
    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
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
        // No clamp on the share burns: like Morpho, over-burning more shares than the
        // position (or market) holds underflows and reverts.
        uint128 posShares = position[id][onBehalf].borrowShares;
        position[id][onBehalf].borrowShares = posShares - SafeCast.toUint128(sharesToBurn);
        m.totalBorrowShares -= SafeCast.toUint128(sharesToBurn);
        // Mirror Morpho's `zeroFloorSub` on totalBorrowAssets: because by-shares repay
        // rounds `assets` UP (toAssetsUp), `assets` can exceed `totalBorrowAssets` by 1
        // when burning the last dust share (real Morpho: "assets may be greater than
        // totalBorrowAssets by 1", Morpho.sol:288-290). A plain subtraction underflows
        // there (panic 0x11) and breaks redeem's flash-repay on a dust-debt position.
        m.totalBorrowAssets =
            SafeCast.toUint128(uint256(m.totalBorrowAssets) > assets ? uint256(m.totalBorrowAssets) - assets : 0);

        // Mirror Morpho: the callback fires after accounting, before the token pull, so a caller can procure the
        // repaid assets within it (redeem's Case-B flash-repay). Gated on non-empty data like Morpho.
        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        MockERC20(mp.loanToken).burn(msg.sender, assets);

        return (assets, sharesToBurn);
    }

    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
        require(assets != 0, "zero assets");
        Id id = mp.id();
        Position storage pos = position[id][onBehalf];

        pos.collateral = SafeCast.toUint128(uint256(pos.collateral) - assets);

        require(_isHealthy(mp, id, onBehalf), "insufficient collateral");

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

    /// @dev Mirrors `Morpho._isHealthy`: debt rounded up (`toAssetsUp`), collateral valued down. Enforced on `borrow`
    /// and `withdrawCollateral` exactly as on-chain, so LLTV violations surface here rather than only on a fork. Use
    /// `liquidate` or an oracle move to construct an underwater position - neither goes through these checks.
    function _isHealthy(MarketParams memory mp, Id id, address user) internal view returns (bool) {
        Position storage pos = position[id][user];
        if (pos.borrowShares == 0) return true;

        Market storage m = market[id];
        uint256 borrowed = _mulDivUp(
            uint256(pos.borrowShares),
            uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS,
            uint256(m.totalBorrowShares) + VIRTUAL_SHARES
        );
        uint256 maxBorrow =
            uint256(pos.collateral) * IOracle(mp.oracle).price() / ORACLE_PRICE_SCALE * mp.lltv / LTV_SCALE;

        return maxBorrow >= borrowed;
    }

    /// @dev Lends from the singleton's own balance rather than minting, so a flash of a token it doesn't custody (e.g.
    /// the loan token, which the vault only borrows) reverts exactly as on-chain — letting tests prove redeem's
    /// Case-B flash is self-collateralized (draws only on supplied collateral, not idle loan).
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(!shouldRevert, "MOCK_MORPHO_DOWN");
        require(assets != 0, "zero assets");
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        MockERC20(token).burn(address(this), assets);
    }
}
