// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";

import {MarketLib} from "./libraries/MarketLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";

// Morpho Blue singleton — same address on every EVM chain.
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue. Three-leg leveraged position:
///         1. Asset leg: collateral token supplied to Morpho.
///         2. Debt leg: loan token borrowed from the market.
///         3. Yield leg: yield token bought with the borrowed loan token.
contract FCMVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    IERC20 public immutable loanToken;
    IERC20 public immutable yieldToken;
    uint24 public immutable feeYieldDebt;
    /// @notice Pool fee tier for the asset/debt pool, used to reconcile
    ///         redeem surplus from loan token back to the underlying asset.
    uint24 public immutable feeAssetDebt;
    uint256 public immutable healthFactorUpperTarget;
    address public immutable yieldOracle;

    MarketParams public market;

    struct InitParams {
        IERC20 collateral;
        IERC20 loanToken;
        IERC20 yieldToken;
        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        uint24 feeYieldDebt;
        uint24 feeAssetDebt;
        uint256 healthFactorUpperTarget;
        address yieldOracle;
        string name;
        string symbol;
    }

    constructor(InitParams memory p) ERC20(p.name, p.symbol) ERC4626(p.collateral) {
        loanToken = p.loanToken;
        yieldToken = p.yieldToken;
        feeYieldDebt = p.feeYieldDebt;
        feeAssetDebt = p.feeAssetDebt;
        healthFactorUpperTarget = p.healthFactorUpperTarget;
        yieldOracle = p.yieldOracle;

        market = MarketParams({
            loanToken: address(p.loanToken),
            collateralToken: address(p.collateral),
            oracle: p.marketOracle,
            irm: p.marketIrm,
            lltv: p.marketLltv
        });

        uint256 maxAllowance = type(uint256).max;
        p.collateral.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
        p.yieldToken.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
    }

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    /// @notice Returns the vault's net asset value (NAV) denominated in the
    ///         underlying asset (collateral token).
    /// @dev    NAV = collateral + yield − debt, with both yield and debt
    ///         converted into asset units using oracle prices:
    ///         - collateral: read directly from the Morpho position.
    ///         - yield: balance of `yieldToken` held by the vault, priced
    ///           through `yieldOracle` and the market oracle (see
    ///           `_yieldToAsset`).
    ///         - debt: outstanding loan-token debt on the Morpho market,
    ///           valued at the market oracle price (see `MarketLib.debt`).
    ///
    ///         Returns 0 if debt exceeds gross value (an underwater
    ///         position). This is a stale read by default — callers that
    ///         need an up-to-the-block NAV must accrue interest on the
    ///         market in the same tx first (see `deposit`).
    function totalAssets() public view override returns (uint256) {
        uint256 assetAmount = market.collateral();
        uint256 yieldInAsset = _yieldToAsset(yieldToken.balanceOf(address(this)));
        uint256 debtInAsset = market.debtToCollateral(market.debt());
        uint256 gross = assetAmount + yieldInAsset;
        if (gross > debtInAsset) {
            return gross - debtInAsset;
        }
        return 0;
    }

    /// @notice Deposit `assets` of the underlying asset into the vault and
    ///         mint vault shares to `receiver`.
    /// @dev    Expansion sequence (see docs/architecture.md §A). Let
    ///         `navBefore` be the vault NAV before this deposit:
    ///         1. Accrue market interest so `navBefore` and the post-deposit
    ///            NAV measurement are both fresh.
    ///         2. Pull `assets` from the caller and supply them as
    ///            collateral to the Morpho market.
    ///         3. Borrow `toBorrow = _targetBorrowAgainst(assets)` loan
    ///            token and swap it into yield token on FlowSwap V3. The
    ///            borrow is capped so this deposit cannot drag the existing
    ///            position's health factor down to the target — small
    ///            deposits never rebalance the whole protocol.
    ///         4. Mint shares pro-rata to the NAV contribution:
    ///            `shares = (totalAssets() − navBefore) ×
    ///                      _totalClaims() / (navBefore + 1)`.
    ///            The `+ 1` is the OZ virtual-asset offset; for the first
    ///            depositor it reduces to `shares = assets × 10**offset`.
    ///
    ///         Rounding favors the vault: the share computation rounds
    ///         down, so any residual NAV accrues to existing shareholders
    ///         rather than the new depositor.
    /// @param  assets   Amount of underlying asset to deposit.
    /// @param  receiver Account to credit with newly minted shares.
    /// @return shares   Vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        market.accrueInterest();

        uint256 navBefore = totalAssets();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(address(loanToken), address(yieldToken), feeYieldDebt, toBorrow);
        }

        uint256 contributed = totalAssets() - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem `shares` of this vault for the underlying asset. The
    ///         owner's shares are burned, a proportional slice of the
    ///         underlying leveraged position is unwound through the AMM, and
    ///         the resulting asset is delivered to `receiver`.
    /// @dev    Unwind sequence (AMM-mediated, see docs/architecture.md §A).
    ///         Let `p = shares / _totalClaims()`, the redeemed fraction of
    ///         the total claim pool (existing supply + virtual-share offset),
    ///         and `d* = p × debt`, the pro-rata debt slice. The unwind:
    ///         1. Sell exactly `p × yieldToken` for loanToken on FlowSwap V3.
    ///            Call the realized loanToken output `loanGot`.
    ///         2. If `loanGot ≥ d*` (Case A — fair or favorable AMM
    ///            execution): repay `d*`, withdraw `p × collateral` of the
    ///            asset, and swap the surplus `loanGot - d*` loanToken to
    ///            the asset.
    ///         3. If `loanGot < d*` (Case B — yield underperformed): repay
    ///            `loanGot`, and withdraw only `p × collateral × loanGot /
    ///            d*` of the asset. Both legs scale by `k = loanGot / d*`,
    ///            which preserves the position's collateral/debt ratio (and
    ///            HF). The un-withdrawn collateral remains in the vault and
    ///            accrues to remaining shareholders; no surplus leg runs.
    ///         4. Burn shares and transfer the new asset balance to receiver.
    ///
    ///         Rounding favors the vault: all pro-rata slices and the
    ///         Case-B scale factor round down, so residuals accrue to
    ///         remaining shareholders rather than leaking to the redeemer.
    ///
    ///         Reverts if `msg.sender != owner` and allowance is
    ///         insufficient.
    /// @param  shares    Vault shares to burn.
    /// @param  receiver  Account to credit with the asset payout.
    /// @param  owner     Account whose shares are burned.
    /// @return assets    Asset actually delivered to `receiver`.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        returns (uint256 assets)
    {
        if (shares == 0) return 0;
        // If someone besides the owner attempts to redeem, this will:
        // 1. Verify the redeemer's allowance is <= shares.
        // 2. Decremement the redeemer's allowance by the amount redeemed.
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        market.accrueInterest();
        IERC20 assetToken = IERC20(asset());
        uint256 assetBefore = assetToken.balanceOf(address(this));

        _unwindSlice(shares);
        _burn(owner, shares);

        assets = assetToken.balanceOf(address(this)) - assetBefore;
        assetToken.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Unwind a slice of the vault's position,
    ///      anchored on `p = shares / _totalClaims()` and the realized AMM
    ///      execution price on the yield leg.
    ///
    ///      Step 1 — yield leg (always full pro-rata):
    ///      Sell exactly `p × yieldToken.balanceOf(vault)` for loanToken on
    ///      the yield/debt pool. Let `loanGot` be the loanToken received
    ///      from this swap (measured as a balance delta so any preexisting
    ///      loanToken dust is not credited to this redeem).
    ///
    ///      Step 2 — branch on realized execution vs. pro-rata debt slice
    ///      `d* = p × debt`:
    ///
    ///      Case A (`loanGot ≥ d*`, fair or favorable execution):
    ///         a. Repay exactly `d*` to Morpho.
    ///         b. Withdraw exactly `p × collateral` of the asset from Morpho.
    ///         c. Reconcile the surplus `loanGot - d*` loanToken to the
    ///            asset on the asset/debt pool. Surplus is real economic
    ///            value (yield leg outgrew the debt leg) and accrues to the
    ///            redeemer.
    ///
    ///      Case B (`loanGot < d*`, yield underperformed at the AMM):
    ///         a. Repay `loanGot` (all of it).
    ///         b. Withdraw `p × collateral × (loanGot / d*)` of the asset.
    ///         Both legs are scaled by the same factor `k = loanGot / d*`,
    ///         preserving the position's collateral/debt ratio (and therefore
    ///         its health factor) post-unwind. The redeemer burns the full
    ///         `shares` but takes home less asset than the fair-price
    ///         outcome would have delivered; the un-withdrawn portion of
    ///         their pro-rata collateral remains in the vault and accrues
    ///         to the remaining shareholders. No surplus reconcile leg runs
    ///         in this case.
    ///
    ///      Rounding favors the vault: pro-rata slices and the scaled
    ///      collateral amount are computed with mulDiv rounding down.
    /// @param shares Vault shares being redeemed (numerator of `p`).
    function _unwindSlice(uint256 shares) internal {
        uint256 claims = _totalClaims();

        // yieldOut is the quantity of yield tokens we are selling to satisfy the redemption
        uint256 yieldOut = yieldToken.balanceOf(address(this)).mulDiv(shares, claims);
        uint256 loanBefore = loanToken.balanceOf(address(this));
        if (yieldOut > 0) {
            SwapLib.swapExactIn(address(yieldToken), address(loanToken), feeYieldDebt, yieldOut);
        }
        uint256 loanGot = loanToken.balanceOf(address(this)) - loanBefore;

        uint256 debtSlice = market.debt().mulDiv(shares, claims);
        uint256 collSlice = market.collateral().mulDiv(shares, claims);

        if (loanGot >= debtSlice) {
            // Case A: full pro-rata unwind, reconcile surplus to the asset.
            if (debtSlice > 0) market.repay(debtSlice);
            if (collSlice > 0) market.withdrawCollateral(collSlice);
            uint256 surplus = loanGot - debtSlice;
            if (surplus > 0) {
                SwapLib.swapExactIn(address(loanToken), asset(), feeAssetDebt, surplus);
            }
        } else {
            // Case B: yield underperformed; scale debt+collateral by
            // k = loanGot / debtSlice to keep the post-unwind HF flat.
            if (loanGot > 0) market.repay(loanGot);
            uint256 scaledColl = collSlice.mulDiv(loanGot, debtSlice);
            if (scaledColl > 0) market.withdrawCollateral(scaledColl);
        }
    }

    /// @notice Not implemented. Use `deposit` instead.
    /// @dev    `mint` would need to invert the borrow-and-swap leg to solve
    ///         for the asset input that produces an exact share output —
    ///         non-trivial because the yield leg goes through an AMM whose
    ///         realized price is only known after execution.
    function mint(
        uint256,
        /*shares*/
        address /*receiver*/
    )
        public
        pure
        override
        returns (uint256)
    {
        revert("not implemented");
    }

    // TODO: reverts
    function withdraw(
        uint256,
        /*assets*/
        address,
        /*receiver*/
        address /*owner*/
    )
        public
        pure
        override
        returns (uint256)
    {
        revert("not implemented");
    }

    /// @dev How much loan token to borrow against `newAssets` while keeping
    ///      the position at `healthFactorUpperTarget`. Returns the smaller
    ///      of two caps:
    ///      - `capFromNewAsset`: the borrow `newAssets` of fresh collateral
    ///        could support on its own at the target HF.
    ///      - `capFromTargetDebt`: the additional borrow that, combined
    ///        with existing debt and existing collateral, would land the
    ///        whole position at the target HF.
    ///
    ///      Taking the min means each deposit borrows at most its own
    ///      proportional share of headroom: small deposits cannot
    ///      rebalance an over-collateralized protocol back to target, and
    ///      no deposit can push an already-too-leveraged position past the
    ///      target HF (`capFromTargetDebt` clamps to 0 in that case).
    function _targetBorrowAgainst(uint256 newAssets) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset =
            market.maxBorrowFor(newAssets).mulDiv(1e18, healthFactorUpperTarget);
        uint256 capFromTargetDebt = market.maxBorrowAtHealthFactor(healthFactorUpperTarget);
        return capFromNewAsset < capFromTargetDebt ? capFromNewAsset : capFromTargetDebt;
    }

    /// @dev Routes yield → debt → asset. The two 1e36 oracle scales cancel.
    function _yieldToAsset(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return yieldAmount.mulDiv(IOracle(yieldOracle).price(), market.oraclePrice());
    }
}
