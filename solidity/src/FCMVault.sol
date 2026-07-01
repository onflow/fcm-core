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
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

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

    /// @dev Q64.96 fixed-point one squared (`2**192`), used to build the
    ///      `sqrtPriceX96` price limit for rebalance swaps.
    uint256 internal constant ONE_X192 = 1 << 192;

    /// @dev Uniswap V3 tick-math bounds on a valid `sqrtPriceLimitX96`. A limit
    ///      outside `(MIN_SQRT_RATIO, MAX_SQRT_RATIO)` is rejected by the pool;
    ///      the vault treats such a limit as "no feasible swap" and skips.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // @dev Address of the loan token (inner vault asset)
    IERC20 public immutable loanToken;
    // @dev Address of the yield token (inner vault share)
    IERC20 public immutable yieldToken;
    // @dev Pool fee for swapping yield<->debt
    uint24 public immutable feeYieldDebt;
    /// @notice The FlowSwap V3 yield/debt pool the rebalance swaps route
    ///         through. Read for its live `slot0` marginal price so a rebalance
    ///         can derive a `sqrtPriceLimitX96` from the oracle and skip when the
    ///         pool is already priced past the slippage bound.
    address public immutable yieldDebtPool;
    /// @notice Pool fee tier for the asset/debt pool, used to reconcile
    ///         redeem surplus from loan token back to the underlying asset.
    uint24 public immutable feeAssetDebt;
    /// @notice Health factor below which `rebalance` will delever (sell yield
    ///         to repay debt). The position is over-levered below this bound.
    ///         WAD-scaled.
    uint256 public immutable healthFactorMin;
    /// @notice Health factor above which `rebalance` will lever up (borrow
    ///         more debt and swap to yield). The position is under-levered
    ///         above this bound. WAD-scaled.
    uint256 public immutable healthFactorMax;
    /// @notice Re-entry target for a delever: when `hf < healthFactorMin`,
    ///         `rebalance` repays just enough debt to raise the health factor
    ///         to this value, which sits just above the lower bound. Landing
    ///         here rather than exactly on `healthFactorMin` leaves a small
    ///         margin so routine drift does not immediately re-trigger.
    ///         WAD-scaled.
    uint256 public immutable healthFactorMinTarget;
    /// @notice Re-entry target for a lever-up: when `hf > healthFactorMax`,
    ///         `rebalance` borrows just enough to lower the health factor to
    ///         this value, which sits just below the upper bound. WAD-scaled.
    ///         The four health factors must satisfy
    ///         `WAD <= healthFactorMin <= healthFactorMinTarget
    ///          <= healthFactorMaxTarget <= healthFactorMax`.
    uint256 public immutable healthFactorMaxTarget;
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

    /// @notice Max price impact (basis points) tolerated on the rebalance swaps
    ///         (lever and delever). It sets each swap's `sqrtPriceLimitX96` to
    ///         the oracle price discounted by this amount, so the pool fills
    ///         only while its marginal price stays within tolerance and
    ///         partial-fills (or skips) past it — rather than reverting. Bounds
    ///         price impact, not the pool's fixed LP fee. Applies only to
    ///         vault-initiated rebalances — deposit/redeem slippage is the
    ///         caller's responsibility, set via the ERC4626 router. Defaults to
    ///         1%, admin-adjustable.
    uint256 public maxSlippageBps;

    /// @notice Emitted when the admin updates `maxSlippageBps`.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);

    /// @dev Thrown when a slippage tolerance >= 100% (10_000 bps) is set.
    error InvalidSlippage();

    // ── Timelocked emergency recovery (custodial, in-kind) ──────────────────
    /// @notice Delay (in seconds) between scheduling and executing a recovery.
    uint256 public immutable recoveryDelay;
    /// @notice Timestamp a scheduled recovery becomes executable; 0 = none pending.
    uint256 public recoveryValidAt;
    /// @notice Set once a recovery executes; permanently blocks new deposits.
    bool public recovered;

    /// @notice Emitted when a recovery is scheduled.
    /// @param  caller  Owner that scheduled it.
    /// @param  validAt Timestamp the recovery becomes executable (`now + recoveryDelay`).
    event EmergencyRecoveryScheduled(address indexed caller, uint256 validAt);
    /// @notice Emitted when a pending recovery is cancelled before execution.
    /// @param  caller Owner that cancelled it.
    event EmergencyRecoveryCancelled(address indexed caller);
    /// @notice Emitted when a recovery executes and the position is swept to the owner.
    /// @param  debtRepaid    Loan token the owner funded to clear the debt.
    /// @param  collateralOut Collateral swept to the owner.
    /// @param  yieldOut      Yield token swept to the owner.
    /// @param  loanOut       Over-funded loan token remainder swept back to the owner.
    event EmergencyRecoveryExecuted(
        uint256 debtRepaid, uint256 collateralOut, uint256 yieldOut, uint256 loanOut
    );

    /// @dev Deposits are frozen while a recovery is pending or after it executes.
    error EmergencyRecoveryActive();
    error EmergencyRecoveryNotReady();

    struct InitParams {
        IERC20 collateral;
        IERC20 loanToken;
        IERC20 yieldToken;
        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        uint24 feeYieldDebt;
        uint24 feeAssetDebt;
        address yieldDebtPool;
        uint256 healthFactorMin;
        uint256 healthFactorMax;
        uint256 healthFactorMinTarget;
        uint256 healthFactorMaxTarget;
        address yieldOracle;
        address admin;
        uint256 recoveryDelay;
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

    /// @notice Emitted at the end of every state-modifying entry point with a
    ///         snapshot of the vault's three legs and their oracle prices. All
    ///         prices are quoted in loan-token (debt) units and 1e36-scaled, so
    ///         `amount * price / 1e36` gives each leg's value in debt units.
    ///         `debtPrice` is the 1e36 scale itself, since debt is already
    ///         denominated in the loan token.
    /// @param  collateral      Collateral supplied to Morpho, raw token units.
    /// @param  debt            Outstanding loan-token debt, raw token units.
    /// @param  yield           Yield token held by the vault, raw token units.
    /// @param  collateralPrice Collateral price in loan token, 1e36-scaled.
    /// @param  debtPrice       Loan-token price in loan token (the 1e36 scale).
    /// @param  yieldPrice      Yield-token price in loan token, 1e36-scaled.
    event VaultState(
        uint256 collateral,
        uint256 debt,
        uint256 yield,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint256 yieldPrice
    );

    /// @dev Emits a `VaultState` snapshot after the wrapped function body runs.
    ///      Placed after `_;` so the event reflects post-call state. Modifying
    ///      entry points accrue market interest before mutating, so the debt
    ///      read here is fresh.
    modifier logsVaultState() {
        _;
        emit VaultState(
            market.collateral(),
            market.debt(),
            yieldToken.balanceOf(address(this)),
            market.oraclePrice(),
            MarketLib.ORACLE_PRICE_SCALE,
            IOracle(yieldOracle).price()
        );
    }

    constructor(InitParams memory p)
        ERC20(p.name, p.symbol)
        ERC4626(p.collateral)
        Ownable(p.admin)
    {
        require(p.healthFactorMin >= MarketLib.WAD, "HF min < WAD");
        require(p.healthFactorMin <= p.healthFactorMinTarget, "HF min > minTarget");
        require(p.healthFactorMinTarget <= p.healthFactorMaxTarget, "HF minTarget > maxTarget");
        require(p.healthFactorMaxTarget <= p.healthFactorMax, "HF maxTarget > max");
        require(p.yieldDebtPool != address(0), "yieldDebtPool zero");

        loanToken = p.loanToken;
        yieldToken = p.yieldToken;
        feeYieldDebt = p.feeYieldDebt;
        feeAssetDebt = p.feeAssetDebt;
        yieldDebtPool = p.yieldDebtPool;
        healthFactorMin = p.healthFactorMin;
        healthFactorMax = p.healthFactorMax;
        healthFactorMinTarget = p.healthFactorMinTarget;
        healthFactorMaxTarget = p.healthFactorMaxTarget;
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

        recoveryDelay = p.recoveryDelay;
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

    /// @dev Resolve the `sqrtPriceLimitX96` for a rebalance swap selling
    ///      `tokenIn` on the yield/debt pool, and decide whether a swap is
    ///      feasible at all.
    ///
    ///      The limit is the oracle price discounted by `maxSlippageBps`,
    ///      expressed in the pool's `sqrt(token1/token0) * 2**96` coordinate.
    ///      The pool fills a swap only while its marginal price is on the good
    ///      side of this limit, so the realized average price is bounded by
    ///      `maxSlippageBps` of *price impact* relative to the oracle.
    ///
    ///      Token decimals are already baked into the yield oracle price (the
    ///      Morpho/IOracle convention: `yield * price / 1e36 = loan` in raw
    ///      units), so the raw `token1/token0` ratio is read straight off it
    ///      with no decimal adjustment here.
    ///
    ///      `ok` is false when the limit is out of tick-math range, or when the
    ///      pool's live marginal price is already on the bad side of the limit
    ///      (so any swap would either be a no-op or revert `SPL`) — in that case
    ///      the caller should skip the swap.
    /// @param  tokenIn The token the swap sells.
    /// @return limit   The Q64.96 price limit to pass to the pool.
    /// @return ok      Whether a swap should be attempted.
    function _yieldDebtSwapLimit(address tokenIn) internal view returns (uint160 limit, bool ok) {
        // Uniswap orders the pair by address: token0 is the lower address and
        // the pool price is token1/token0. Selling token0 (`zeroForOne`) pushes
        // the price down; selling token1 pushes it up.
        bool yieldIsToken0 = address(yieldToken) < address(loanToken);
        address token0 = yieldIsToken0 ? address(yieldToken) : address(loanToken);
        bool zeroForOne = (tokenIn == token0);

        // Oracle price as an exact token1/token0 fraction. yieldOracle.price()
        // is loan-per-yield scaled by 1e36. yield=token0 -> P = loan/yield =
        // price/1e36; loan=token0 -> P = yield/loan = 1e36/price.
        uint256 yieldPrice = IOracle(yieldOracle).price();
        (uint256 numerator, uint256 denominator) = yieldIsToken0
            ? (yieldPrice, MarketLib.ORACLE_PRICE_SCALE)
            : (MarketLib.ORACLE_PRICE_SCALE, yieldPrice);

        // Discount the price toward the side the swap moves it: a
        // price-decreasing swap allows down to price*(1-slip); a price-increasing
        // swap allows up to price/(1-slip).
        if (zeroForOne) {
            numerator *= (BPS - maxSlippageBps);
            denominator *= BPS;
        } else {
            numerator *= BPS;
            denominator *= (BPS - maxSlippageBps);
        }

        // sqrtPriceX96 = sqrt(P) * 2**96 = sqrt(P * 2**192).
        uint256 raw = Math.sqrt(Math.mulDiv(numerator, ONE_X192, denominator));
        if (raw <= MIN_SQRT_RATIO || raw >= MAX_SQRT_RATIO) return (0, false);

        // The limit must sit on the side the price moves toward: below spot for
        // a price-decreasing swap, above spot for a price-increasing one. If the
        // pool is already past it, there is no room to trade within tolerance.
        (uint160 spot,,,,,,) = IUniswapV3Pool(yieldDebtPool).slot0();
        if (zeroForOne && raw >= spot) return (0, false)
        if (!zeroForOne && raw <= spot) return (0, false)

        return (uint160(raw), true);
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
    function deposit(uint256 assets, address receiver)
        public
        override
        logsVaultState
        returns (uint256 shares)
    {
        // Freeze deposits while a recovery is pending (recoveryValidAt != 0) or done
        // (recovered) — don't let new funds in ahead of a sweep. Redeems stay open.
        if (recoveryValidAt != 0 || recovered) revert EmergencyRecoveryActive();
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
        logsVaultState
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
        logsVaultState
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

    /// @notice Drive the vault's leveraged Morpho position back inside the
    ///         `[healthFactorMin, healthFactorMax]` band, rebalancing only to
    ///         the re-entry target just inside the nearest bound rather than to
    ///         a central target.
    /// @dev    Behavior:
    ///         - If `hf ∈ [healthFactorMin, healthFactorMax]`, the call is a
    ///           no-op.
    ///         - If `hf > healthFactorMax`, the position is under-levered:
    ///           borrow exactly `addDebt = (maxBorrow / maxTarget) - debt` of
    ///           the loan token and swap it to the yield token, landing HF at
    ///           `healthFactorMaxTarget` (just below the upper bound).
    ///         - If `hf < healthFactorMin`, the position is over-levered:
    ///           sell exactly enough yield token to repay
    ///           `repayAmount = debt - (maxBorrow / minTarget)` of debt,
    ///           landing HF at `healthFactorMinTarget` (just above the lower
    ///           bound).
    ///
    ///         Rebalancing to the re-entry target nearest the breached bound
    ///         minimizes swap volume per rebalance. Swap cost is price impact
    ///         plus pool fees - both are proportional to swap volume.
    ///         So, the smallest swap that restores health within the band incurs
    ///         the lowest average-case cost. By convention, there is a small
    ///         buffer between the band's bound and the target.
    ///
    ///         Partial rebalancing: the rebalance swap carries a
    ///         `sqrtPriceLimitX96` derived from the oracle price and
    ///         `maxSlippageBps` (see `_yieldDebtSwapLimit`). If reaching the
    ///         re-entry target would push the pool past that price, the pool
    ///         fills as much as possible without reverting.
    ///
    ///         Note the bound is on the pool's *marginal price* relative to the
    ///         oracle, i.e. on price impact. The pool's fixed LP fee is a
    ///         separate, known cost and is not part of this bound.
    function rebalance() external logsVaultState {
        // After a recovery the position is terminal; revert with an explicit
        // error so the off-chain rebalancer surfaces it and stops, rather than
        // silently no-op'ing and running indefinitely.
        if (recovered) revert EmergencyRecoveryActive();
        market.accrueInterest();
        uint256 currentDebt = market.debt();
        uint256 maxBorrow = market.maxBorrow(); // independent of current debt balance
        // we compute inline here rather than use MarketLib.healthFactor to save a SLOAD
        uint256 hfBefore =
            currentDebt == 0 ? type(uint256).max : maxBorrow.mulDiv(MarketLib.WAD, currentDebt);

        if (hfBefore > healthFactorMax) {
            _rebalanceLever(maxBorrow, currentDebt);
        } else if (hfBefore < healthFactorMin) {
            _rebalanceDelever(maxBorrow, currentDebt);
        } else {
            // Inside the dead band — nothing to do.
            return;
        }

        emit Rebalanced(msg.sender, hfBefore, market.healthFactor());
    }

    /// @dev Lever-up branch of `rebalance`: position is under-levered
    ///      (`hf > healthFactorMax`). Borrow exactly the debt slice that lands
    ///      the position at `healthFactorMaxTarget` and swap it into yield token.
    ///
    ///      `targetDebt = maxBorrow * WAD / healthFactorMaxTarget` is the debt
    ///      level that, against the current collateral, produces an HF of
    ///      exactly `healthFactorMaxTarget` (just below the upper bound).
    ///      Since `hf > max >= maxTarget`, `currentDebt < targetDebt`. The
    ///      borrow leg adds `targetDebt - currentDebt`.
    ///
    ///      Partial: the full `borrowAmount` is borrowed up front, then the
    ///      loan->yield swap runs under a `sqrtPriceLimitX96` derived from the
    ///      oracle and `maxSlippageBps`. If the swap would push the pool past
    ///      that price, the pool fills only up to it (a partial fill) and the
    ///      unspent loan token is immediately repaid, so the position lands
    ///      partway to `healthFactorMaxTarget` with no idle loan token left
    ///      behind. Borrowing first and repaying the remainder (rather than
    ///      sizing the borrow to the fill) avoids needing the swap output before
    ///      the tokens to swap exist. When the pool is already priced past the
    ///      bound, the swap is skipped and the borrow is fully repaid (no-op).
    /// @param maxBorrow   Current maximum-borrowable amount at LLTV (independent of current debt)
    /// @param currentDebt Current outstanding debt (caller passes the same
    ///                    value used to compute `hfBefore` to avoid a
    ///                    second `MORPHO.position` SLOAD).
    /// @return additionalDebt Net new debt taken on in this call (the loan token
    ///                    actually swapped into yield; 0 if nothing filled).
    function _rebalanceLever(uint256 maxBorrow, uint256 currentDebt)
        internal
        returns (uint256 additionalDebt)
    {
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, healthFactorMaxTarget);
        if (targetDebt <= currentDebt) return 0;
        uint256 borrowAmount = targetDebt - currentDebt;

        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(loanToken));
        if (!ok) return 0; // pool already past the slippage bound — no-op.

        // Borrow first, then swap loan->yield bounded by the price limit. The
        // pool partial-fills up to the limit; whatever loan it does not consume
        // stays with the vault and is repaid below, so we only lever by the
        // amount actually converted to yield.
        uint256 loanBefore = loanToken.balanceOf(address(this));
        market.borrow(borrowAmount);
        SwapLib.swapExactInToLimit(
            address(loanToken), address(yieldToken), feeYieldDebt, borrowAmount, limit
        );

        // Repay the loan token the swap left behind, so no idle loan lingers.
        uint256 leftover = loanToken.balanceOf(address(this)) - loanBefore;
        if (leftover > 0) market.repay(leftover);
        additionalDebt = borrowAmount - leftover;
    }

    /// @dev Delever branch of `rebalance`: position is over-levered
    ///      (`hf < healthFactorMin`). Sell yield token for loan token to repay
    ///      enough debt to land the position back at `healthFactorMinTarget`.
    ///
    ///      Sizing:
    ///        targetDebt    = maxBorrow * WAD / healthFactorMinTarget
    ///        repayAmount   = currentDebt - targetDebt
    ///        yieldToSell   = repayAmount * 1e36 / yieldOraclePrice
    ///
    ///      `yieldToSell` is the oracle-implied yield amount whose loan-token
    ///      value equals `repayAmount`. AMM slippage shows up as a small
    ///      under-shoot (post-rebalance HF is slightly below
    ///      `healthFactorMinTarget` if the swap realized less than oracle).
    ///
    ///      Partial: the yield->loan swap runs under a `sqrtPriceLimitX96`
    ///      derived from the oracle and `maxSlippageBps`. If selling the full
    ///      `yieldToSell` would push the pool past that price, the pool fills
    ///      only up to it and the vault repays just the realized loan token, so
    ///      the position lands partway to `healthFactorMinTarget` rather than
    ///      reverting. When the pool is already priced past the bound the swap
    ///      is skipped entirely (no-op).
    ///
    /// @param maxBorrow   Current maximum-borrowable amount at LLTV (may be 0
    ///                    after a liquidation that wiped collateral).
    /// @param currentDebt Current outstanding debt.
    /// @return repaid Amount of loan token repaid to Morpho in this call.
    function _rebalanceDelever(uint256 maxBorrow, uint256 currentDebt)
        internal
        returns (uint256 repaid)
    {
        // conceptually, target debt is maxBorrow / healthFactorMinTarget
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, healthFactorMinTarget);
        if (targetDebt >= currentDebt) return 0;
        uint256 repayAmount = currentDebt - targetDebt;

        uint256 yieldPrice = IOracle(yieldOracle).price();
        // Oracle-implied yield amount whose loan-token value equals
        // `repayAmount` (not accounting for slippage)
        uint256 yieldToSell = repayAmount.mulDiv(MarketLib.ORACLE_PRICE_SCALE, yieldPrice);

        uint256 yieldBalance = yieldToken.balanceOf(address(this));
        if (yieldToSell > yieldBalance) yieldToSell = yieldBalance;
        if (yieldToSell == 0) return 0;

        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(yieldToken));
        if (!ok) return 0; // pool already past the slippage bound — no-op.

        // Sell yield->loan bounded by the price limit. The pool partial-fills
        // up to it, so a too-large delever still repays as much as the bound
        // allows.
        uint256 loanGot = SwapLib.swapExactInToLimit(
            address(yieldToken), address(loanToken), feeYieldDebt, yieldToSell, limit
        );

        // Cap repayment at outstanding debt
        repaid = loanGot > currentDebt ? currentDebt : loanGot;
        if (repaid > 0) market.repay(repaid);
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

    /// @dev The health factor `deposit` levers fresh collateral toward: the
    ///      midpoint of the rebalance band. `rebalance` only acts at the band's
    ///      edges, so deposits aim for the center to leave symmetric headroom
    ///      in both directions before the position drifts to a bound and
    ///      triggers a rebalance.
    function _depositTargetHf() internal view returns (uint256) {
        return (healthFactorMin + healthFactorMax) / 2;
    }

    /// @dev How much loan token to borrow against `newAssets` while keeping
    ///      the position at the deposit-target HF (`_depositTargetHf`, the
    ///      band midpoint). Returns the smaller of two caps:
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
    ///      Protocol-wide rebalancing (driving the whole position back inside
    ///      the band regardless of new asset size) is the job of `rebalance`,
    ///      not `deposit`.
    function _targetBorrowAgainst(uint256 newAssets) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 targetHf = _depositTargetHf();
        uint256 capFromNewAsset = market.maxBorrowFor(newAssets).mulDiv(MarketLib.WAD, targetHf);
        uint256 capFromTargetDebt = market.maxBorrowAtHealthFactor(targetHf);
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

    /// @notice Schedule a timelocked emergency recovery. Executable after
    ///         `recoveryDelay`; the owner may cancel in the meantime.
    function scheduleEmergencyRecovery() external onlyOwner {
        recoveryValidAt = block.timestamp + recoveryDelay;
        emit EmergencyRecoveryScheduled(msg.sender, recoveryValidAt);
    }

    /// @notice Cancel a pending recovery during its timelock window.
    function cancelEmergencyRecovery() external onlyOwner {
        recoveryValidAt = 0;
        emit EmergencyRecoveryCancelled(msg.sender);
    }

    /// @notice Execute a scheduled recovery once its timelock elapses. The owner
    ///         funds the full debt in `loanToken`; the position is fully unwound
    ///         (no swap) and all assets are swept to the owner. Burns no shares and
    ///         permanently blocks deposits. `redeem` stays callable throughout the
    ///         window so holders may exit first.
    function executeEmergencyRecovery() external onlyOwner {
        if (recoveryValidAt == 0 || block.timestamp < recoveryValidAt) {
            revert EmergencyRecoveryNotReady();
        }
        recoveryValidAt = 0;
        recovered = true;

        market.accrueInterest();

        // Owner funds the full debt; repay by shares so the position zeros exactly.
        uint256 debtRepaid = market.debt();
        loanToken.safeTransferFrom(msg.sender, address(this), debtRepaid);
        market.repayAll();

        // Free all collateral now that the debt is cleared.
        uint256 collateralOut = market.collateral();
        if (collateralOut > 0) market.withdrawCollateral(collateralOut);

        // Sweep everything to the owner, in kind.
        address to = owner();
        uint256 yieldOut = yieldToken.balanceOf(address(this));
        uint256 loanOut = loanToken.balanceOf(address(this)); // over-funded remainder
        if (collateralOut > 0) IERC20(asset()).safeTransfer(to, collateralOut);
        if (yieldOut > 0) yieldToken.safeTransfer(to, yieldOut);
        if (loanOut > 0) loanToken.safeTransfer(to, loanOut);

        emit EmergencyRecoveryExecuted(debtRepaid, collateralOut, yieldOut, loanOut);
    }

    /// @inheritdoc IERC4626
    /// @notice Remaining headroom under the TVL limit, clamped to 0 when full.
    /// @dev Even if the inner vault has hit its own deposit limit, we may still
    ///      be able to obtain shares of it on the AMM to satisfy the deposit.
    ///      However, if we implement 'direct deposit' to the inner vault,
    ///      its own maxDeposit() will bind.
    function maxDeposit(address receiver) public view override returns (uint256) {
        // The emergency recovery deposit freeze is enforced by the guard in deposit();
        // maxDeposit mirrors it as 0 because ERC-4626 requires reporting 0 when deposits
        // are disabled.
        if (recoveryValidAt != 0 || recovered) return 0;
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
