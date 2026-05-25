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

// ---- Flow EVM mainnet addresses ----------------------------------------

IERC20  constant WETH   = IERC20(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
IERC20  constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
IERC20  constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);
address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue. Three-leg leveraged position:
///         1. Asset leg: WETH supplied as Morpho collateral.
///         2. Debt leg: PYUSD0 borrowed from that market.
///         3. Yield leg: FUSDEV bought with the borrowed PYUSD0.
contract FCMVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    uint256 public constant MARKET_LLTV = 0.86e18;
    uint24 public constant FEE_YIELD_DEBT = 100; // PYUSD0/FUSDEV pool
    uint24 public constant FEE_ASSET_DEBT = 3000; // WETH/PYUSD0 pool, used to reconcile redeem surplus
    uint256 public constant HF_UPPER_TARGET = 1.45e18; // 1e18-scaled target HF for deposit sizing
    uint8 internal constant DECIMALS_OFFSET = 6;

    MarketParams public market;
    address public immutable yieldOracle;

    constructor(
        address marketOracle,
        address yieldOracle_
    ) ERC20("Flow Credit Markets WETH", "fcmWETH") ERC4626(WETH) {
        market = MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WETH),
            oracle: marketOracle,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
        yieldOracle = yieldOracle_;

        uint256 maxAllowance = type(uint256).max;
        WETH.forceApprove(address(MORPHO), maxAllowance);
        PYUSD0.forceApprove(address(MORPHO), maxAllowance);
        PYUSD0.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
        FUSDEV.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 assetAmount = market.collateral();
        uint256 yieldInAsset = _yieldToAsset(FUSDEV.balanceOf(address(this)));
        uint256 debtInAsset = market.debtToCollateral(market.debt());
        uint256 gross = assetAmount + yieldInAsset;
        if (gross > debtInAsset) {
            return gross - debtInAsset;
        }
        return 0;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        market.accrueInterest();

        uint256 navBefore = totalAssets();

        WETH.safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(
                address(PYUSD0),
                address(FUSDEV),
                FEE_YIELD_DEBT,
                toBorrow
            );
        }

        uint256 contributed = totalAssets() - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem `shares` of this vault for WETH. The owner's shares
    ///         are burned, a proportional slice of the underlying leveraged
    ///         position is unwound through the AMM, and the resulting WETH
    ///         is delivered to `receiver`.
    /// @dev    Three-address ERC-4626 semantics: `owner` is whose shares are
    ///         burned, `receiver` is who the WETH is sent to, `msg.sender`
    ///         is the caller. When `msg.sender != owner`, an ERC-20
    ///         allowance from `owner` covering `shares` is consumed inside
    ///         this call via `_spendAllowance`. This split lets routers and
    ///         vault wrappers redeem on a user's behalf without a separate
    ///         transferFrom step.
    ///
    ///         Unwind sequence (AMM-mediated, see docs/architecture.md §A).
    ///         Let `p = shares / _totalClaims()`, the redeemed fraction of
    ///         the total claim pool (existing supply + virtual-share offset):
    ///         1. Sell `p × FUSDEV` for PYUSD0 on FlowSwap V3 (yield→debt).
    ///         2. Repay up to `p × debt` of PYUSD0 to Morpho. Capped at the
    ///            PYUSD0 received in step 1, so an AMM slip cannot revert
    ///            the call directly (it surfaces in step 3 instead).
    ///         3. Withdraw `p × collateral` of WETH from Morpho. Morpho
    ///            enforces post-state HF ≥ 1; if step 2 under-repaid badly,
    ///            this step reverts.
    ///         4. Reconcile any leftover PYUSD0 to WETH on the WETH/PYUSD0
    ///            pool (handles surplus from yield accrual).
    ///         5. Burn shares and transfer the new WETH balance to receiver.
    ///
    ///         Rounding favors the vault: all proportional slices round
    ///         down, so residuals accrue to remaining shareholders rather
    ///         than leaking to the redeemer.
    ///
    ///         Reverts if `msg.sender != owner` and allowance is
    ///         insufficient, or if the post-repay HF would be < 1 (Morpho
    ///         rejects the collateral withdrawal in step 3). Returns 0
    ///         immediately when `shares == 0`, with no state change.
    /// @param  shares    Vault shares to burn.
    /// @param  receiver  Account to credit with the WETH payout.
    /// @param  owner     Account whose shares are burned.
    /// @return assets    WETH actually delivered to `receiver`. May differ
    ///                   from `previewRedeem(shares)` by AMM fees +
    ///                   slippage + price drift across the two swap legs.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        if (shares == 0) return 0;
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        market.accrueInterest();
        uint256 wethBefore = WETH.balanceOf(address(this));

        _unwindSlice(shares);
        _burn(owner, shares);

        assets = WETH.balanceOf(address(this)) - wethBefore;
        WETH.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Unwind a proportional slice of the three legs of the vault's
    ///      position, sized to `p = shares / _totalClaims()`. Extracted from
    ///      `redeem` to keep that function under Solidity's stack limit.
    ///
    ///      `_totalClaims()` is `totalSupply() + 10**_decimalsOffset()` —
    ///      the virtual offset is OpenZeppelin's inflation-attack defense.
    ///      Including it in the denominator means a 100% redeem leaves a
    ///      tiny non-redeemable residual in each leg (intentional).
    ///
    ///      Steps:
    ///      1. Sell `p × FUSDEV.balanceOf(vault)` for PYUSD0 on the
    ///         yield/debt pool.
    ///      2. Repay `min(p × debt, vault PYUSD0 balance)` to Morpho. The
    ///         min() is a defense: if the AMM under-delivered PYUSD0 (high
    ///         slippage), capping the repay at the actual balance avoids a
    ///         transferFrom revert; the consequence surfaces in step 3 via
    ///         Morpho's HF ≥ 1 check.
    ///      3. Withdraw `p × collateral` of WETH from Morpho.
    ///      4. Reconcile any remaining PYUSD0 in the vault to WETH on the
    ///         asset/debt pool. Non-zero leftover occurs when the yield leg
    ///         has outgrown the debt leg (vault is profitable) — that
    ///         profit is converted to the user's payout currency here.
    /// @param shares Vault shares being redeemed (numerator of `p`).
    function _unwindSlice(uint256 shares) internal {
        uint256 claims = _totalClaims();

        uint256 yieldOut = FUSDEV.balanceOf(address(this)).mulDiv(shares, claims);
        if (yieldOut > 0) {
            SwapLib.swapExactIn(address(FUSDEV), address(PYUSD0), FEE_YIELD_DEBT, yieldOut);
        }

        uint256 debtTarget = market.debt().mulDiv(shares, claims);
        uint256 pyusdBal = PYUSD0.balanceOf(address(this));
        uint256 toRepay = debtTarget < pyusdBal ? debtTarget : pyusdBal;
        if (toRepay > 0) market.repay(toRepay);

        uint256 collateralOut = market.collateral().mulDiv(shares, claims);
        if (collateralOut > 0) market.withdrawCollateral(collateralOut);

        uint256 surplus = PYUSD0.balanceOf(address(this));
        if (surplus > 0) {
            SwapLib.swapExactIn(address(PYUSD0), address(WETH), FEE_ASSET_DEBT, surplus);
        }
    }

    /// @notice Withdraw approximately `assets` worth of WETH from the vault.
    /// @dev    Thin wrapper that converts `assets` to a share count via
    ///         OpenZeppelin's `previewWithdraw` (NAV-based, rounds shares up
    ///         so the vault is never under-paid) and delegates to `redeem`.
    ///
    ///         CAVEAT vs the strict ERC-4626 contract: the spec says
    ///         `withdraw` should deliver exactly `assets` of the underlying.
    ///         Because our unwind is path-dependent (two AMM swaps), the
    ///         WETH actually delivered to `receiver` may differ from
    ///         `assets` by AMM fees + slippage. Integrators that need exact
    ///         asset amounts should compose with their own slippage-checked
    ///         router.
    /// @param  assets    Target WETH amount used to size the share count.
    /// @param  receiver  Account to credit with the WETH payout.
    /// @param  owner     Account whose shares are burned.
    /// @return shares    Shares burned (`= previewWithdraw(assets)`).
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        redeem(shares, receiver, owner);
    }

    /// @dev How much PYUSD0 to borrow against `newAssets` while keeping the
    ///      position at `HF_UPPER_TARGET`.
    function _targetBorrowAgainst(
        uint256 newAssets
    ) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset = market.maxBorrowFor(newAssets).mulDiv(
            1e18,
            HF_UPPER_TARGET
        );
        uint256 capFromTargetDebt = market.maxBorrowAtHf(HF_UPPER_TARGET);
        return
            capFromNewAsset < capFromTargetDebt
                ? capFromNewAsset
                : capFromTargetDebt;
    }

    /// @dev Routes yield → debt → asset. The two 1e36 oracle scales cancel.
    function _yieldToAsset(
        uint256 yieldAmount
    ) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return
            yieldAmount.mulDiv(
                IOracle(yieldOracle).price(),
                market.oraclePrice()
            );
    }
}
