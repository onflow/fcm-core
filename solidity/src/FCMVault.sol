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

IERC20 constant WETH = IERC20(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
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
    /// @dev    Unwind sequence (AMM-mediated, see docs/architecture.md §A).
    ///         Let `p = shares / _totalClaims()`, the redeemed fraction of
    ///         the total claim pool (existing supply + virtual-share offset),
    ///         and `d* = p × debt`, the pro-rata debt slice. The unwind:
    ///         1. Sell exactly `p × FUSDEV` for PYUSD0 on FlowSwap V3. Call
    ///            the realized PYUSD0 output `pyusdGot`.
    ///         2. If `pyusdGot ≥ d*` (Case A — fair or favorable AMM
    ///            execution): repay `d*`, withdraw `p × collateral` of WETH,
    ///            and swap the surplus `pyusdGot - d*` PYUSD0 to WETH.
    ///         3. If `pyusdGot < d*` (Case B — yield underperformed): repay
    ///            `pyusdGot`, and withdraw only `p × collateral × pyusdGot /
    ///            d*` of WETH. Both legs scale by `k = pyusdGot / d*`, which
    ///            preserves the position's collateral/debt ratio (and HF).
    ///            The un-withdrawn collateral remains in the vault and
    ///            accrues to remaining shareholders; no surplus leg runs.
    ///         4. Burn shares and transfer the new WETH balance to receiver.
    ///
    ///         Rounding favors the vault: all pro-rata slices and the
    ///         Case-B scale factor round down, so residuals accrue to
    ///         remaining shareholders rather than leaking to the redeemer.
    ///
    ///         Reverts if `msg.sender != owner` and allowance is
    ///         insufficient.
    /// @param  shares    Vault shares to burn.
    /// @param  receiver  Account to credit with the WETH payout.
    /// @param  owner     Account whose shares are burned.
    /// @return assets    WETH actually delivered to `receiver`.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        if (shares == 0) return 0;
        // If someone besides the owner attempts to redeem, this will:
        // 1. Verify the redeemer's allowance is <= shares.
        // 2. Decremement the redeemer's allowance by the amount redeemed.
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        market.accrueInterest();
        uint256 wethBefore = WETH.balanceOf(address(this));

        _unwindSlice(shares);
        _burn(owner, shares);

        assets = WETH.balanceOf(address(this)) - wethBefore;
        WETH.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Unwind a slice of the vault's position,
    ///      anchored on `p = shares / _totalClaims()` and the realized AMM
    ///      execution price on the yield leg.
    ///
    ///      Step 1 — yield leg (always full pro-rata):
    ///      Sell exactly `p × FUSDEV.balanceOf(vault)` for PYUSD0 on the
    ///      yield/debt pool. Let `pyusdGot` be the PYUSD0 received from
    ///      this swap (measured as a balance delta so any preexisting
    ///      PYUSD0 dust is not credited to this redeem).
    ///
    ///      Step 2 — branch on realized execution vs. pro-rata debt slice
    ///      `d* = p × debt`:
    ///
    ///      Case A (`pyusdGot ≥ d*`, fair or favorable execution):
    ///         a. Repay exactly `d*` to Morpho.
    ///         b. Withdraw exactly `p × collateral` of WETH from Morpho.
    ///         c. Reconcile the surplus `pyusdGot - d*` PYUSD0 to WETH on
    ///            the asset/debt pool. Surplus is real economic value (yield
    ///            leg outgrew the debt leg) and accrues to the redeemer.
    ///
    ///      Case B (`pyusdGot < d*`, yield underperformed at the AMM):
    ///         a. Repay `pyusdGot` (all of it).
    ///         b. Withdraw `p × collateral × (pyusdGot / d*)` of WETH.
    ///         Both legs are scaled by the same factor `k = pyusdGot / d*`,
    ///         preserving the position's collateral/debt ratio (and therefore
    ///         its health factor) post-unwind. The redeemer burns the full
    ///         `shares` but takes home less WETH than the fair-price
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
        uint256 yieldOut = FUSDEV.balanceOf(address(this)).mulDiv(
            shares,
            claims
        );
        uint256 pyusdBefore = PYUSD0.balanceOf(address(this));
        if (yieldOut > 0) {
            SwapLib.swapExactIn(
                address(FUSDEV),
                address(PYUSD0),
                FEE_YIELD_DEBT,
                yieldOut
            );
        }
        uint256 pyusdGot = PYUSD0.balanceOf(address(this)) - pyusdBefore;

        uint256 debtSlice = market.debt().mulDiv(shares, claims);
        uint256 collSlice = market.collateral().mulDiv(shares, claims);

        if (pyusdGot >= debtSlice) {
            // Case A: full pro-rata unwind, reconcile surplus to WETH.
            if (debtSlice > 0) market.repay(debtSlice);
            if (collSlice > 0) market.withdrawCollateral(collSlice);
            uint256 surplus = pyusdGot - debtSlice;
            if (surplus > 0) {
                SwapLib.swapExactIn(
                    address(PYUSD0),
                    address(WETH),
                    FEE_ASSET_DEBT,
                    surplus
                );
            }
        } else {
            // Case B: yield underperformed; scale debt+collateral by
            // k = pyusdGot / debtSlice to keep the post-unwind HF flat.
            if (pyusdGot > 0) market.repay(pyusdGot);
            uint256 scaledColl = collSlice.mulDiv(pyusdGot, debtSlice);
            if (scaledColl > 0) market.withdrawCollateral(scaledColl);
        }
    }

    // TODO: reverts
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        revert("not implemented");
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
