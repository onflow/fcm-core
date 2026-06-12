// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";

import {MarketLib} from "./libraries/MarketLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";

// Morpho Blue singleton address for Flow EVM
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue with role-gated participation.
///         Three-leg leveraged position:
///         1. Asset leg: collateral token supplied to Morpho.
///         2. Debt leg: loan token borrowed from the market.
///         3. Yield leg: yield token bought with the borrowed loan token.
///
///         Holders of `EARLY_ACCESS_ROLE` may deposit, hold, and transfer
///         shares. Burns (withdrawals/redeems) are always permitted so a
///         removed holder can still exit.
contract FCMVault is ERC4626, AccessControl, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    /// @notice Members of this role may deposit assets, hold shares, and
    ///         transfer shares.
    bytes32 public constant EARLY_ACCESS_ROLE = keccak256("EARLY_ACCESS_ROLE");

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Basis-points denominator for `maxSlippageBps`.
    uint256 internal constant BPS = 10_000;

    // @dev Address of the loan token (inner vault asset)
    IERC20 public immutable loanToken;
    // @dev Address of the yield token (inner vault share)
    IERC20 public immutable yieldToken;
    // @dev Pool fee for swapping yield<->debt
    uint24 public immutable feeYieldDebt;
    /// @notice Pool fee tier for the asset/debt pool, used to reconcile
    ///         redeem surplus from loan token back to the underlying asset.
    uint24 public immutable feeAssetDebt;
    /// @notice Health factor below which `rebalance` will delever (sell yield
    ///         to repay debt). WAD-scaled.
    uint256 public immutable healthFactorMin;
    /// @notice Health factor above which `rebalance` will lever up (borrow
    ///         more debt and swap to yield). WAD-scaled.
    uint256 public immutable healthFactorMax;
    /// @notice Health factor that `rebalance` drives the position toward
    ///         whenever it acts. Also used by `deposit` to cap the
    ///         per-deposit borrow. WAD-scaled; must satisfy
    ///         `healthFactorMin < healthFactorTarget < healthFactorMax`.
    uint256 public immutable healthFactorTarget;
    // @dev Address of the oracle for the yield token.
    //      We will deploy an oracle instance, which will provide the best available price information
    //      for the given token. This may be a 3rd party oracle, onchain price information, or both.
    address public immutable yieldOracle;

    MarketParams public market;

    /// @notice TVL limit, denominated in the vault's Asset token.
    ///         Enforced by `super.deposit`, which reverts with
    ///         `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`.
    ///         Default 0 -> no deposits until admin raises it.
    ///         - This constraint prevents all deposits/mints which would cause the vault to exceed
    ///           the configured TVL limit after the deposit/mint completes.
    ///         - This constraint does not prevent any withdrawals/redeems under any circumstances.
    ///         - This constraint does not prevent the vault from holding more assets than its configured TVL.
    ///           This can happen if:
    ///            - The owner sets maxTvl to a value lower than the current totalAssets
    ///            - The value of vault holdings increases above the TVL limit due to market conditions.
    ///              This can occur without any direct interactions with the vault.
    uint256 public maxTvl;

    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);

    /// @notice Max slippage (basis points) tolerated on the rebalance swaps
    ///         (lever and delever). The swap's `amountOutMinimum` is the
    ///         oracle-expected output discounted by this; a worse fill reverts
    ///         the rebalance. Applies only to vault-initiated rebalances —
    ///         deposit/redeem slippage is the caller's responsibility, set via
    ///         the ERC4626 router. Defaults to 1%, admin-adjustable.
    uint256 public maxSlippageBps;

    /// @notice Emitted when the admin updates `maxSlippageBps`.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);

    /// @dev Thrown when a slippage tolerance >= 100% (10_000 bps) is set.
    error InvalidSlippage();

    struct InitParams {
        IERC20 collateral;
        IERC20 loanToken;
        IERC20 yieldToken;
        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        uint24 feeYieldDebt;
        uint24 feeAssetDebt;
        uint256 healthFactorMin;
        uint256 healthFactorMax;
        uint256 healthFactorTarget;
        address yieldOracle;
        address admin;
        string name;
        string symbol;
    }

    /// @notice Emitted whenever the vault is re-balanced
    /// @param  caller             Address that invoked `rebalance`.
    /// @param  healthFactorBefore Health factor at the start of the call (WAD-scaled).
    /// @param  healthFactorAfter  Health factor after the rebalance (WAD-scaled).
    event Rebalanced(address indexed caller, uint256 healthFactorBefore, uint256 healthFactorAfter);

    /// @notice Emitted on a `redeemInKind` (escape hatch): `owner`'s `shares`
    ///         burned, `caller` repaid `debtRepaid` loanToken, `receiver` got
    ///         `collateralOut` collateral + `yieldOut` yield in kind.
    event RedeemInKind(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 shares,
        uint256 debtRepaid,
        uint256 collateralOut,
        uint256 yieldOut
    );

    constructor(InitParams memory p)
        ERC20(p.name, p.symbol)
        ERC4626(p.collateral)
        Ownable(p.admin)
    {
        require(p.healthFactorMin >= MarketLib.WAD, "HF min < WAD");
        require(p.healthFactorMin <= p.healthFactorTarget, "HF min > target");
        require(p.healthFactorTarget <= p.healthFactorMax, "HF target > max");

        loanToken = p.loanToken;
        yieldToken = p.yieldToken;
        feeYieldDebt = p.feeYieldDebt;
        feeAssetDebt = p.feeAssetDebt;
        healthFactorMin = p.healthFactorMin;
        healthFactorMax = p.healthFactorMax;
        healthFactorTarget = p.healthFactorTarget;
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

        maxSlippageBps = 100; // 1% default; admin retunes per pool depth.

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
    }

    /// @notice Set the max slippage tolerance applied to the rebalance swaps.
    /// @param  newBps Tolerance in basis points; must be < 100% (10_000) so the
    ///         floor can never be fully disabled.
    function setMaxSlippageBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps >= BPS) revert InvalidSlippage();
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @dev Discount an oracle-expected swap output by `maxSlippageBps` to get
    ///      the `amountOutMinimum` floor for a rebalance swap.
    function _slippageFloor(uint256 expectedOut) internal view returns (uint256) {
        return expectedOut.mulDiv(BPS - maxSlippageBps, BPS);
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
    ///         4. Mint shares pro-rata to the NAV contribution
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
        if (navBefore + assets > maxTvl) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(address(loanToken), address(yieldToken), feeYieldDebt, toBorrow);
        }

        // the depositor's contribution to NAV, denominated in outer vault assets
        uint256 contributed = totalAssets() - navBefore;
        // mint shares in proportion to the depositor's contribution
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1); // +1 rounds in favour of the vaults
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
    ///         TODO: Redemptions should use flash loans in the future to ensure
    ///         collateral withdrawals can always be used to satisfy redemptions.
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
    ///      TODO: Redemptions should use flash loans in the future to ensure
    ///      collateral withdrawals can always be used to satisfy redemptions.
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

    /// @notice Escape hatch — swap-free, in-kind redemption: the caller
    ///         repays `owner`'s pro-rata debt slice in `loanToken` and burns
    ///         `owner`'s `shares`; `receiver` receives the pro-rata collateral and
    ///         yield tokens directly. Needs no swap — the yield leg is delivered
    ///         in kind rather than sold on the AMM; the collateral leg still
    ///         settles through Morpho. Rounding favors the vault: the debt slice
    ///         rounds up, collateral/yield slices round down.
    ///
    ///         Reverts if `msg.sender != owner` and allowance is insufficient, if
    ///         the caller has not approved this vault for the debt slice, or if the
    ///         position is underwater (Morpho blocks the collateral withdrawal).
    /// @param  shares        Vault shares to burn.
    /// @param  receiver      Account credited with the collateral + yield in kind.
    /// @param  owner         Account whose shares are burned and whose pro-rata
    ///                       debt the caller repays.
    /// @return collateralOut Collateral tokens delivered to `receiver`.
    /// @return yieldOut      Yield tokens delivered to `receiver`.
    function redeemInKind(uint256 shares, address receiver, address owner)
        public
        returns (uint256 collateralOut, uint256 yieldOut)
    {
        if (shares == 0) return (0, 0);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        market.accrueInterest();
        uint256 claims = _totalClaims();

        // Caller repays the pro-rata debt slice (rounded up — never under-repays);
        // the caller supplies the loanToken, so no swap is needed.
        uint256 debtRepaid = market.debt().mulDiv(shares, claims, Math.Rounding.Ceil);
        if (debtRepaid > 0) {
            loanToken.safeTransferFrom(msg.sender, address(this), debtRepaid);
            market.repay(debtRepaid);
        }

        // Pro-rata collateral + yield, delivered in kind (rounded down).
        collateralOut = market.collateral().mulDiv(shares, claims);
        yieldOut = yieldToken.balanceOf(address(this)).mulDiv(shares, claims);

        _burn(owner, shares);

        if (collateralOut > 0) {
            market.withdrawCollateral(collateralOut);
            IERC20(asset()).safeTransfer(receiver, collateralOut);
        }
        if (yieldOut > 0) yieldToken.safeTransfer(receiver, yieldOut);

        emit RedeemInKind(msg.sender, receiver, owner, shares, debtRepaid, collateralOut, yieldOut);
    }

    /// @notice Drive the vault's leveraged Morpho position back toward
    ///         `healthFactorTarget`.
    /// @dev    Normal (non-forced) behavior:
    ///         - If `hf ∈ [healthFactorMin, healthFactorMax]`, the call is a
    ///           no-op
    ///         - If `hf > healthFactorMax`, the position is under-levered:
    ///           borrow exactly `addDebt = (maxBorrow / target) - debt` of
    ///           the loan token and swap it to the yield token.
    ///         - If `hf < healthFactorMin`, the position is over-levered:
    ///           sell exactly enough yield token to repay
    ///           `repayAmount = debt - (maxBorrow / target)` of debt.
    ///
    /// @param  force If true, rebalance regardless of current health factor
    function rebalance(bool force) external {
        market.accrueInterest();
        uint256 currentDebt = market.debt();
        uint256 maxBorrow = market.maxBorrow(); // independent of current debt balance
        // we compute inline here rather than use MarketLib.healthFactor to save a SLOAD
        uint256 hfBefore =
            currentDebt == 0 ? type(uint256).max : maxBorrow.mulDiv(MarketLib.WAD, currentDebt);

        if (!force) {
            if (hfBefore >= healthFactorMin && hfBefore <= healthFactorMax) {
                return;
            }
        }

        if (hfBefore > healthFactorTarget) {
            _rebalanceLever(maxBorrow, currentDebt);
        } else if (hfBefore < healthFactorTarget) {
            _rebalanceDelever(maxBorrow, currentDebt);
        }

        emit Rebalanced(msg.sender, hfBefore, market.healthFactor());
    }

    /// @dev Lever-up branch of `rebalance`: position is under-levered
    ///      (`hf > target`). Borrow exactly the debt slice that lands the
    ///      position at `healthFactorTarget` and swap it into yield token.
    ///
    ///      `targetDebt = maxBorrow * WAD / healthFactorTarget` is the debt
    ///      level that, against the current collateral, produces an HF of
    ///      exactly target. Since `hf > target`, `currentDebt < targetDebt`.
    ///      The borrow leg adds `targetDebt - currentDebt`.
    /// @param maxBorrow   Current maximum-borrowable amount at LLTV (independent of current debt)
    /// @param currentDebt Current outstanding debt (caller passes the same
    ///                    value used to compute `hfBefore` to avoid a
    ///                    second `MORPHO.position` SLOAD).
    /// @return additionalDebt Amount of loan token borrowed in this call.
    function _rebalanceLever(uint256 maxBorrow, uint256 currentDebt)
        internal
        returns (uint256 additionalDebt)
    {
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, healthFactorTarget);
        if (targetDebt <= currentDebt) return 0;
        additionalDebt = targetDebt - currentDebt;

        market.borrow(additionalDebt);
        // Floor the loan->yield swap at the oracle-expected yield out, less
        // maxSlippageBps. Deposit's identical leg is intentionally unfloored
        // (user-facing slippage is the router's job); this leg is
        // vault-initiated, so the floor is the price-impact / sandwich guard.
        uint256 expectedYield =
            additionalDebt.mulDiv(MarketLib.ORACLE_PRICE_SCALE, IOracle(yieldOracle).price());
        SwapLib.swapExactInMin(
            address(loanToken),
            address(yieldToken),
            feeYieldDebt,
            additionalDebt,
            _slippageFloor(expectedYield)
        );
    }

    /// @dev Delever branch of `rebalance`: position is over-levered
    ///      (`hf < target`). Sell yield token for loan token to repay
    ///      enough debt to land the position back at `healthFactorTarget`.
    ///
    ///      Sizing:
    ///        targetDebt    = maxBorrow * WAD / healthFactorTarget
    ///        repayAmount   = currentDebt - targetDebt
    ///        yieldToSell   = repayAmount * 1e36 / yieldOraclePrice
    ///
    ///      `yieldToSell` is the oracle-implied yield amount whose loan-token
    ///      value equals `repayAmount`. AMM slippage shows up as a small
    ///      under-shoot of target (post-rebalance HF is slightly below
    ///      target if the swap realized less than oracle).
    ///
    /// @param maxBorrow   Current maximum-borrowable amount at LLTV (may be 0
    ///                    after a liquidation that wiped collateral).
    /// @param currentDebt Current outstanding debt.
    /// @return repaid Amount of loan token repaid to Morpho in this call.
    function _rebalanceDelever(uint256 maxBorrow, uint256 currentDebt)
        internal
        returns (uint256 repaid)
    {
        // conceptually, target debt is maxBorrow / hfTarget
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, healthFactorTarget);
        if (targetDebt >= currentDebt) return 0;
        uint256 repayAmount = currentDebt - targetDebt;

        uint256 yieldPrice = IOracle(yieldOracle).price();
        // Oracle-implied yield amount whose loan-token value equals
        // `repayAmount` (not accounting for slippage)
        uint256 yieldToSell = repayAmount.mulDiv(MarketLib.ORACLE_PRICE_SCALE, yieldPrice);

        uint256 yieldBalance = yieldToken.balanceOf(address(this));
        if (yieldToSell > yieldBalance) yieldToSell = yieldBalance;
        if (yieldToSell == 0) return 0;

        uint256 loanBefore = loanToken.balanceOf(address(this));
        // Floor the yield->loan swap at the oracle-expected loan out for the
        // (possibly-capped) yieldToSell, less maxSlippageBps. Redeem's identical
        // leg is intentionally unfloored (router's job); this vault-initiated
        // leg gets the price-impact / sandwich guard.
        uint256 expectedLoan = yieldToSell.mulDiv(yieldPrice, MarketLib.ORACLE_PRICE_SCALE);
        SwapLib.swapExactInMin(
            address(yieldToken),
            address(loanToken),
            feeYieldDebt,
            yieldToSell,
            _slippageFloor(expectedLoan)
        );
        uint256 loanGot = loanToken.balanceOf(address(this)) - loanBefore;

        // Cap repayment at outstanding debt
        repayAmount = loanGot > currentDebt ? currentDebt : loanGot;
        if (repayAmount > 0) market.repay(repayAmount);
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
    ///      the position at `healthFactorTarget`. Returns the smaller
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
    ///
    ///      Protocol-wide rebalancing (driving the whole position back to
    ///      `healthFactorTarget` regardless of new asset size) is the job of
    ///      `rebalance`, not `deposit`.
    function _targetBorrowAgainst(uint256 newAssets) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset =
            market.maxBorrowFor(newAssets).mulDiv(MarketLib.WAD, healthFactorTarget);
        uint256 capFromTargetDebt = market.maxBorrowAtHealthFactor(healthFactorTarget);
        return capFromNewAsset < capFromTargetDebt ? capFromNewAsset : capFromTargetDebt;
    }

    /// @dev Routes yield → debt → asset. The two 1e36 oracle scales cancel.
    function _yieldToAsset(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return yieldAmount.mulDiv(IOracle(yieldOracle).price(), market.oraclePrice());
    }

    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    /// @param newMaxTvl the new TVL limit; applies only to new deposits.
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @inheritdoc IERC4626
    /// @notice Remaining headroom under the TVL limit, clamped to 0 when full.
    /// @dev Even if the inner vault has hit its own deposit limit, we may still
    ///      be able to obtain shares of it on the AMM to satisfy the deposit.
    ///      However, if we implement 'direct deposit' to the inner vault,
    ///      its own maxDeposit() will bind.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        uint256 cachedTotalAssets = totalAssets();
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @inheritdoc IERC4626
    /// @notice Mint is disabled in favor of deposit.
    function maxMint(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        return 0;
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn).
    ///      - Mint (`from == 0`): the receiver must be allowlisted.
    ///      - Transfer (both non-zero): both sender and receiver must be allowlisted.
    ///      - Burn (`to == 0`): always allowed, preserving the exit path for
    ///        de-allowlisted holders.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (!hasRole(EARLY_ACCESS_ROLE, to)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(to, EARLY_ACCESS_ROLE);
            }
            if (from != address(0) && !hasRole(EARLY_ACCESS_ROLE, from)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(from, EARLY_ACCESS_ROLE);
            }
        }
        super._update(from, to, value);
    }
}
