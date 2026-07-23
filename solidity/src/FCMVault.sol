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
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
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
contract FCMVault is ERC4626, AccessControl, Ownable2Step, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    /// @notice Members of this role may deposit assets, hold shares, and
    ///         transfer shares.
    bytes32 public constant EARLY_ACCESS_ROLE = keccak256("EARLY_ACCESS_ROLE");

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Basis-points denominator (10_000 = 100%).
    uint256 internal constant BPS = 10_000;

    /// @dev Seconds in a year, for the time-based management fee accrual.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @dev Hard cap on the management fee (10%/yr) — admin cannot exceed.
    uint256 internal constant MAX_MANAGEMENT_FEE_BPS = 1_000;
    /// @dev Hard cap on the performance fee (50%) — admin cannot exceed.
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 5_000;

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
    /// @notice FlowSwap V3 asset/debt pool for the harvest loan->collateral leg. Its
    ///         live `slot0` price is read to bound leg 2 to the market oracle, skipping
    ///         when the pool is already past the slippage bound.
    address public immutable assetDebtPool;
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
    /// @notice The yield factor is `yieldValue / debt`, WAD-scaled (WAD = the yield exactly
    ///         repays the debt). It is NOT a yield rate. `yieldFactorMax` is the upper edge of
    ///         its band: `rebalance`'s harvest leg fires only when the yield factor exceeds it,
    ///         so it does not act on sub-threshold surplus. Must be `>= WAD`. Immutable, like the
    ///         health-factor band bounds.
    uint256 public immutable yieldFactorMax;
    /// @dev Address of the oracle for the yield token.
    ///      We will deploy an oracle instance, which will provide the best available price information
    ///      for the given token. This may be a 3rd party oracle, onchain price information, or both.
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
    event EmergencyRecoveryExecuted(uint256 debtRepaid, uint256 collateralOut, uint256 yieldOut, uint256 loanOut);

    /// @dev Deposits are frozen while a recovery is pending or after it executes.
    error EmergencyRecoveryActive();
    error EmergencyRecoveryNotReady();

    // ── Management & performance fees ──────────────────────────────────────
    /// @notice Flat yearly management fee on NAV, in basis points. 0 = off.
    /// @dev    Linear accrual of the annual rate; bounded by the 10% cap.
    uint256 public managementFeeBps;
    /// @notice Performance fee on per-share gains above the high-water mark, in
    ///         basis points. 0 = off.
    /// @dev    Crystallizes on UNREALIZED, oracle-marked NAV and is triggerable by
    ///         anyone via `accrueFees`; bounded by the all-time HWM and the 50% cap.
    uint256 public performanceFeeBps;
    /// @notice Recipient of minted fee shares. Must hold `EARLY_ACCESS_ROLE` to
    ///         receive them; if unset or not allowlisted, fee accrual is skipped
    ///         (never reverts) so core flows can't be bricked.
    address public feeRecipient;
    /// @notice Timestamp of the last fee accrual, for the time-based management fee.
    uint256 public lastFeeAccrual;
    /// @notice High-water mark for the performance fee, as asset-per-share scaled
    ///         by WAD (`NAV * WAD / claims`). Flow-neutral, strict all-time peak.
    ///         Vault-wide (one mark for all holders): a depositor entering below it
    ///         rides the recovery back up fee-free — accepted by design in lieu of
    ///         per-user-HWM accounting.
    uint256 public perfHighWaterMark;

    /// @notice Emitted when the admin updates the management fee (old + new).
    event ManagementFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the admin updates the performance fee (old + new).
    event PerformanceFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the admin updates the fee recipient (old + new).
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when fees are accrued and shares minted to the recipient.
    /// @param  recipient      Account that received the minted fee shares.
    /// @param  managementFee  Management fee accrued this call, in asset terms.
    /// @param  performanceFee Performance fee accrued this call, in asset terms.
    /// @param  feeShares      Shares minted to `recipient` (dilution).
    event FeesAccrued(address indexed recipient, uint256 managementFee, uint256 performanceFee, uint256 feeShares);

    /// @dev Thrown when a fee rate above its hard cap is set.
    error InvalidFee();

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
        address assetDebtPool;
        uint256 healthFactorMin;
        uint256 healthFactorMax;
        uint256 healthFactorMinTarget;
        uint256 healthFactorMaxTarget;
        uint256 yieldFactorMax;
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

    /// @notice Emitted when the harvest leg of `rebalance` sells surplus yield and
    ///         redeploys it as collateral.
    /// @param  yieldSold       Yield token sold (the surplus above debt backing).
    /// @param  collateralAdded Collateral supplied from the swap proceeds.
    event Harvested(uint256 yieldSold, uint256 collateralAdded);

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
        uint256 collateral, uint256 debt, uint256 yield, uint256 collateralPrice, uint256 debtPrice, uint256 yieldPrice
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

    constructor(InitParams memory p) ERC20(p.name, p.symbol) ERC4626(p.collateral) Ownable(p.admin) {
        require(p.healthFactorMin >= MarketLib.WAD, "HF min < WAD");
        require(p.healthFactorMin <= p.healthFactorMinTarget, "HF min > minTarget");
        require(p.healthFactorMinTarget <= p.healthFactorMaxTarget, "HF minTarget > maxTarget");
        require(p.healthFactorMaxTarget <= p.healthFactorMax, "HF maxTarget > max");
        require(p.yieldFactorMax >= MarketLib.WAD, "yieldFactorMax < WAD");
        require(p.yieldDebtPool != address(0), "yieldDebtPool zero");
        require(p.assetDebtPool != address(0), "assetDebtPool zero");

        loanToken = p.loanToken;
        yieldToken = p.yieldToken;
        feeYieldDebt = p.feeYieldDebt;
        feeAssetDebt = p.feeAssetDebt;
        yieldDebtPool = p.yieldDebtPool;
        assetDebtPool = p.assetDebtPool;
        healthFactorMin = p.healthFactorMin;
        healthFactorMax = p.healthFactorMax;
        healthFactorMinTarget = p.healthFactorMinTarget;
        healthFactorMaxTarget = p.healthFactorMaxTarget;
        yieldFactorMax = p.yieldFactorMax;
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
        // redeem's Case-B flash sells collateral for the debt shortfall.
        p.collateral.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);

        recoveryDelay = p.recoveryDelay;
        maxSlippageBps = 100; // 1% default; admin retunes per pool depth.

        lastFeeAccrual = block.timestamp;
        // Seed the HWM at the starting price-per-share so the first deposit isn't counted as performance.
        perfHighWaterMark = MarketLib.WAD / (10 ** DECIMALS_OFFSET);

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
    }

    /// @notice Set the max slippage tolerance applied to the rebalance swaps.
    /// @param  newBps Tolerance in basis points; must be < 100% (10_000) so the
    ///         floor can never be fully disabled.
    function setMaxSlippageBps(uint256 newBps) external onlyOwner {
        if (newBps >= BPS) revert InvalidSlippage();
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @dev Resolve the `sqrtPriceLimitX96` and a go/skip flag for a swap selling
    ///      `tokenIn` for `tokenOut` on `pool`, bounding price impact to `maxSlippageBps`
    ///      away from a fair rate of `outPerInNum / outPerInDen` (`tokenOut` per `tokenIn`,
    ///      with token decimals already baked into the fraction). Pure Uniswap-price math:
    ///      it does not know or care which token is the loan/oracle side.
    ///
    ///      The pool price is `token1/token0` (token0 = the lower-address token). The fair
    ///      rate is mapped to that coordinate and discounted toward the side the swap moves
    ///      it: selling token0 (`zeroForOne`) drives the price down (limit below spot),
    ///      selling token1 drives it up (limit above spot). The pool then fills only while
    ///      its marginal price is on the good side of the limit, so the realized average
    ///      price is bounded by `maxSlippageBps` of price impact relative to the fair rate.
    ///
    ///      `ok` is false when the limit is out of tick-math range, or when the pool's live
    ///      marginal price is already on the bad side of it (any swap would no-op or revert
    ///      `SPL`) — the caller then skips.
    /// @param  pool        The Uniswap V3 pool for the `tokenIn`/`tokenOut` pair.
    /// @param  tokenIn     The token the swap sells.
    /// @param  tokenOut    The token the swap buys.
    /// @param  outPerInNum Numerator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param  outPerInDen Denominator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @return limit       The Q64.96 price limit to pass to the pool.
    /// @return ok          Whether a swap should be attempted.
    function _swapLimit(address pool, address tokenIn, address tokenOut, uint256 outPerInNum, uint256 outPerInDen)
        internal
        view
        returns (uint160 limit, bool ok)
    {
        // Uniswap orders the pair by address: token0 is the lower-address token
        // and the pool price is token1/token0. Selling token0 (`zeroForOne`) pushes
        // the price down; selling token1 pushes it up.
        bool zeroForOne = tokenIn < tokenOut;

        // Fair price as an exact token1/token0 fraction. Selling token0 makes token1/token0
        // the tokenOut/tokenIn rate (outPerIn); selling token1 makes it the reciprocal, so
        // the numerator and denominator swap.
        (uint256 numerator, uint256 denominator) = zeroForOne ? (outPerInNum, outPerInDen) : (outPerInDen, outPerInNum);

        // Discount the price toward the side the swap moves it: a price-decreasing swap
        // allows down to price*(1-slip); a price-increasing swap up to price/(1-slip).
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

        // The limit must sit on the side the price moves toward: below spot for a
        // price-decreasing swap, above spot for a price-increasing one. If the pool
        // is already past it, there is no room to trade within tolerance.
        // slither-disable-next-line unused-return -> only sqrtPriceX96 is read; the other slot0 fields are unused
        (uint160 spot,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (zeroForOne && raw >= spot) return (0, false);
        if (!zeroForOne && raw <= spot) return (0, false);

        return (uint160(raw), true);
    }

    /// @dev Price limit for a swap on the yield/debt pool (rebalance lever/delever and
    ///      harvest leg 1). The yield oracle quotes loan per yield token, 1e36-scaled.
    function _yieldDebtSwapLimit(address tokenIn) internal view returns (uint160, bool) {
        uint256 loanPerYield = IOracle(yieldOracle).price();
        return tokenIn == address(yieldToken)
            ? _swapLimit(yieldDebtPool, tokenIn, address(loanToken), loanPerYield, MarketLib.ORACLE_PRICE_SCALE)
            : _swapLimit(yieldDebtPool, tokenIn, address(yieldToken), MarketLib.ORACLE_PRICE_SCALE, loanPerYield);
    }

    /// @dev Price limit for harvest leg 2's loan->collateral swap on the asset/debt
    ///      pool. The market oracle quotes loan per collateral, 1e36-scaled.
    function _assetDebtSwapLimit() internal view returns (uint160, bool) {
        return
            _swapLimit(assetDebtPool, address(loanToken), asset(), MarketLib.ORACLE_PRICE_SCALE, market.oraclePrice());
    }

    /// @notice Set the management fee rate (basis points), capped at `MAX_MANAGEMENT_FEE_BPS`.
    /// @dev    Accrues at the OLD rate first so the change isn't retroactive.
    // slither-disable-next-line reentrancy-no-eth -> admin-only setter; _accrueFees only calls the trusted Morpho singleton, which cannot reenter
    function setManagementFeeBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_MANAGEMENT_FEE_BPS) revert InvalidFee();
        _accrueFees();
        emit ManagementFeeSet(managementFeeBps, newBps);
        managementFeeBps = newBps;
    }

    /// @notice Set the performance fee rate (basis points), capped at `MAX_PERFORMANCE_FEE_BPS`.
    /// @dev    Accrues at the OLD rate first so the change isn't retroactive.
    // slither-disable-next-line reentrancy-no-eth -> admin-only setter; _accrueFees only calls the trusted Morpho singleton, which cannot reenter
    function setPerformanceFeeBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_PERFORMANCE_FEE_BPS) revert InvalidFee();
        _accrueFees();
        emit PerformanceFeeSet(performanceFeeBps, newBps);
        performanceFeeBps = newBps;
    }

    /// @notice Set the fee recipient. Accrues to the old recipient first.
    /// @dev    The recipient must hold `EARLY_ACCESS_ROLE` to receive minted fee
    ///         shares; if it doesn't, accrual silently skips (see `_accrueFees`).
    // slither-disable-next-line reentrancy-no-eth -> admin-only setter; _accrueFees only calls the trusted Morpho singleton, which cannot reenter
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _accrueFees();
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Permissionlessly accrue fees up to the current block (mints fee
    ///         shares to the recipient). Lets a keeper tick the management fee
    ///         during idle stretches so it tracks NAV-over-time more closely.
    function accrueFees() external {
        _accrueFees();
    }

    /// @dev Accrue management + performance fees and mint the corresponding
    ///      shares to `feeRecipient` (dilution — no assets leave the vault).
    ///      Always accrues market interest first so NAV is fresh. No-ops once
    ///      `recovered`. Skips minting (never reverts) when the recipient is
    ///      unset or not allowlisted, so core flows can't be bricked.
    function _accrueFees() internal {
        if (recovered) return;

        market.accrueInterest();
        uint256 nav = totalAssets();
        uint256 claims = _totalClaims();
        uint256 pps = nav.mulDiv(MarketLib.WAD, claims);

        address recipient = feeRecipient;
        if (recipient != address(0) && hasRole(EARLY_ACCESS_ROLE, recipient) && nav > 0) {
            // Bill exactly `rate * Δt` since the last accrual, then advance the clock
            // (accrual is irregular: every interaction + permissionless accrueFees).
            // The billable gap is capped at one year, so the fee is
            // provably <= the annual rate `r` (= bps/1e4) however long the vault
            // sits unaccrued - idle time past a year is forgiven, bounding a single
            // catch-up dilution after long dormancy. Within a year the realized drag
            // lies in `[1 - e^(-r), r]`: `r` at one accrual/year, `1 - e^(-r)` in the
            // continuous limit (negligible span <= ~r^2/2: ~0.02% at bps=200,
            // ~0.48% at the 1000 cap).
            uint256 elapsed = block.timestamp - lastFeeAccrual;
            if (elapsed > SECONDS_PER_YEAR) elapsed = SECONDS_PER_YEAR;

            uint256 managementFee = 0;
            if (managementFeeBps > 0 && elapsed > 0) {
                managementFee = nav.mulDiv(managementFeeBps * elapsed, BPS * SECONDS_PER_YEAR);
            }

            uint256 performanceFee = 0;
            if (performanceFeeBps > 0 && pps > perfHighWaterMark) {
                // Fee on the gain in pps above the all-time HWM. pps is UNREALIZED and
                // oracle-marked, so a transient mark move can crystallize a fee on paper
                // profit that later reverses - kept, not refunded. The mint goes to the
                // recipient, not the triggerer, so a permissionless accrueFees call can't
                // pay its caller; the strict HWM charges net all-time highs only.
                uint256 gain = (pps - perfHighWaterMark).mulDiv(claims, MarketLib.WAD);
                performanceFee = gain.mulDiv(performanceFeeBps, BPS);
            }

            uint256 feeAssets = managementFee + performanceFee;
            if (feeAssets > 0 && feeAssets < nav) {
                // Mint shares worth `feeAssets` at the post-mint price (dilution).
                uint256 feeShares = feeAssets.mulDiv(claims, nav + 1 - feeAssets);
                if (feeShares > 0) {
                    _mint(recipient, feeShares);
                    emit FeesAccrued(recipient, managementFee, performanceFee, feeShares);
                }
            }
        }

        // Advance clock + HWM unconditionally (even when the mint was skipped) so
        // fees meter from when they're enabled, not retroactively — the fee setters
        // accrue first, pinning these to now. Gating them on the mint would
        // back-charge holders from deploy.
        lastFeeAccrual = block.timestamp;
        if (pps > perfHighWaterMark) perfHighWaterMark = pps;
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
    function deposit(uint256 assets, address receiver) public override logsVaultState returns (uint256 shares) {
        // Freeze deposits while a recovery is pending (recoveryValidAt != 0) or done
        // (recovered) — don't let new funds in ahead of a sweep. Redeems stay open.
        if (recoveryValidAt != 0 || recovered) revert EmergencyRecoveryActive();
        // Accrue fees first so the deposit prices in at the post-fee share price.
        _accrueFees();

        uint256 navBefore = totalAssets();
        if (navBefore + assets > maxTvl) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            // slither-disable-next-line unused-return -> swap output is measured via the totalAssets() delta below, not this return
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
    ///         3. If `loanGot < d*` (Case B — yield underperformed): flash-borrow
    ///            the shortfall `d* - loanGot` in loanToken, repay the full `d*`,
    ///            withdraw the full `p × collateral`, and sell just enough of that
    ///            collateral to repay the flash. The redeemer takes home their
    ///            full pro-rata value; the collateral sold covers the debt the
    ///            yield leg could not.
    ///         4. Burn shares and transfer the new asset balance to receiver.
    ///
    ///         Rounding favors the vault: all pro-rata slices round down, so
    ///         residuals accrue to remaining shareholders rather than leaking to
    ///         the redeemer.
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

        // Accrue fees first so the redeemer bears their share of accrued fees.
        _accrueFees();
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
    ///         a. Flash-borrow the shortfall `d* - loanGot` in loanToken from
    ///            Morpho, so the vault holds the full `d*`.
    ///         b. Repay the full `d*` to Morpho, then withdraw the full
    ///            `p × collateral`. Repaying before withdrawing makes the
    ///            withdrawal health-factor-neutral, so it is permitted at any
    ///            health factor (see `onMorphoFlashLoan`).
    ///         c. Sell just enough of the withdrawn collateral back to loanToken
    ///            to repay the flash. The redeemer takes home their full pro-rata
    ///            value; the collateral sold covers the debt the yield leg could
    ///            not. No surplus reconcile leg runs in this case.
    ///
    ///      Rounding favors the vault: pro-rata slices are computed with mulDiv
    ///      rounding down.
    /// @param shares Vault shares being redeemed (numerator of `p`).
    function _unwindSlice(uint256 shares) internal {
        uint256 claims = _totalClaims();

        // yieldOut is the quantity of yield tokens we are selling to satisfy the redemption
        uint256 yieldOut = yieldToken.balanceOf(address(this)).mulDiv(shares, claims);
        uint256 loanBefore = loanToken.balanceOf(address(this));
        if (yieldOut > 0) {
            // slither-disable-next-line unused-return -> loanGot is measured from the loanToken balance delta below, not this return
            SwapLib.swapExactIn(address(yieldToken), address(loanToken), feeYieldDebt, yieldOut);
        }
        uint256 loanGot = loanToken.balanceOf(address(this)) - loanBefore;

        uint256 debtSlice = market.debt().mulDiv(shares, claims);
        uint256 collSlice = market.collateral().mulDiv(shares, claims);

        if (loanGot >= debtSlice) {
            // Case A: full pro-rata unwind, reconcile surplus to the asset.
            // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
            if (debtSlice > 0) market.repay(debtSlice);
            if (collSlice > 0) market.withdrawCollateral(collSlice);
            uint256 surplus = loanGot - debtSlice;
            if (surplus > 0) {
                // slither-disable-next-line unused-return -> surplus-swap output is captured by the redeem balance delta, not this return
                SwapLib.swapExactIn(address(loanToken), asset(), feeAssetDebt, surplus);
            }
        } else {
            // Case B: the yield sale (loanGot) fell short of the pro-rata debt
            // slice. Cover the shortfall by selling a slice of the redeemer's own
            // collateral so they get their full pro-rata value instead of a
            // scaled-down haircut. A Morpho flash loan supplies the shortfall so
            // the full debt slice is repaid BEFORE the collateral is withdrawn,
            // making the withdrawal hf-neutral and permitted at any health factor.
            // The unsold collateral is delivered to the redeemer as the asset
            // balance delta (see `onMorphoFlashLoan`).
            MORPHO.flashLoan(address(loanToken), debtSlice - loanGot, abi.encode(debtSlice, collSlice));
        }
    }

    /// @notice Morpho flash-loan callback for redeem's Case-B path. Only callable
    ///         by Morpho, which only invokes it when the vault itself initiated the
    ///         flash loan (Morpho calls back the caller of `flashLoan`).
    /// @dev    On entry the vault holds `loanGot` (from the yield sale) plus the
    ///         flash-borrowed `shortfall`, together the full pro-rata `debtSlice`.
    ///         Repay the slice, withdraw the redeemer's full `collSlice`, then sell
    ///         exactly `shortfall` of it back to loan token to repay the flash. The
    ///         unsold collateral stays as the vault's asset balance and is
    ///         delivered to the redeemer by `redeem`. Reverts if the redeemer's own
    ///         collateral slice cannot cover the shortfall (genuinely underwater).
    function onMorphoFlashLoan(uint256 shortfall, bytes calldata data) external {
        require(msg.sender == address(MORPHO), "unauthorized");
        (uint256 debtSlice, uint256 collSlice) = abi.decode(data, (uint256, uint256));

        // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
        market.repay(debtSlice);
        market.withdrawCollateral(collSlice);
        // Sell collateral for exactly `shortfall` loan token to repay the flash,
        // spending at most the withdrawn slice; the rest stays for the redeemer.
        // slither-disable-next-line unused-return -> collateral spent is captured by the redeem balance delta, not this return
        SwapLib.swapExactOut(asset(), address(loanToken), feeAssetDebt, shortfall, collSlice);
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

        // Accrue fees first so the redeemer bears their share of accrued fees.
        _accrueFees();
        uint256 claims = _totalClaims();

        // Caller repays the pro-rata debt slice (rounded up — never under-repays);
        // the caller supplies the loanToken, so no swap is needed.
        uint256 debtRepaid = market.debt().mulDiv(shares, claims, Math.Rounding.Ceil);
        if (debtRepaid > 0) {
            loanToken.safeTransferFrom(msg.sender, address(this), debtRepaid);
            // slither-disable-next-line unused-return -> repay amount is known (debtRepaid); Morpho reverts on failure
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
    ///         `[healthFactorMin, healthFactorMax]` band and realize surplus yield above the
    ///         yield-factor band.
    /// @dev    Two legs: `_harvest` (realize surplus) then `_adjustLeverage` (restore the
    ///         band).
    function rebalance() external logsVaultState {
        // After a recovery the position is terminal; revert with an explicit
        // error so the off-chain rebalancer surfaces it and stops, rather than
        // silently no-op'ing and running indefinitely.
        if (recovered) revert EmergencyRecoveryActive();
        _accrueFees();

        // harvest must run before _adjustLeverage
        _harvest();
        _adjustLeverage();
    }

    /// @dev Leverage leg of `rebalance`, rebalancing only to the re-entry target just
    ///      inside the nearest bound rather than to a central target.
    ///      - If `hf ∈ [healthFactorMin, healthFactorMax]`, the call is a
    ///        no-op.
    ///      - If `hf > healthFactorMax`, the position is under-levered:
    ///        borrow exactly `addDebt = (maxBorrow / maxTarget) - debt` of
    ///        the loan token and swap it to the yield token, landing HF at
    ///        `healthFactorMaxTarget` (just below the upper bound).
    ///      - If `hf < healthFactorMin`, the position is over-levered:
    ///        sell exactly enough yield token to repay
    ///        `repayAmount = debt - (maxBorrow / minTarget)` of debt,
    ///        landing HF at `healthFactorMinTarget` (just above the lower
    ///        bound).
    ///
    ///      Rebalancing to the re-entry target nearest the breached bound
    ///      minimizes swap volume per rebalance. Swap cost is price impact
    ///      plus pool fees - both are proportional to swap volume.
    ///      So, the smallest swap that restores health within the band incurs
    ///      the lowest average-case cost. By convention, there is a small
    ///      buffer between the band's bound and the target.
    ///
    ///      Partial rebalancing: the rebalance swap carries a
    ///      `sqrtPriceLimitX96` derived from the oracle price and
    ///      `maxSlippageBps` (see `_yieldDebtSwapLimit`). If reaching the
    ///      re-entry target would push the pool past that price, the pool
    ///      fills as much as possible without reverting.
    ///
    ///      Note the bound is on the pool's *marginal price* relative to the
    ///      oracle, i.e. on price impact. The pool's fixed LP fee is a
    ///      separate, known cost and is not part of this bound.
    function _adjustLeverage() internal {
        uint256 currentDebt = market.debt();
        uint256 maxBorrow = market.maxBorrow(); // independent of current debt balance
        // we compute inline here rather than use MarketLib.healthFactor to save a SLOAD
        uint256 hfBefore = currentDebt == 0 ? type(uint256).max : maxBorrow.mulDiv(MarketLib.WAD, currentDebt);

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
    function _rebalanceLever(uint256 maxBorrow, uint256 currentDebt) internal returns (uint256 additionalDebt) {
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
        // slither-disable-next-line unused-return -> levered amount is measured via the loanToken balance delta below, not this return
        SwapLib.swapExactInToLimit(address(loanToken), address(yieldToken), feeYieldDebt, borrowAmount, limit);

        // Repay the loan token the swap left behind, so no idle loan lingers.
        uint256 leftover = loanToken.balanceOf(address(this)) - loanBefore;
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
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
    function _rebalanceDelever(uint256 maxBorrow, uint256 currentDebt) internal returns (uint256 repaid) {
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
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing to sell, so skip the swap
        if (yieldToSell == 0) return 0;

        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(yieldToken));
        if (!ok) return 0; // pool already past the slippage bound — no-op.

        // Sell yield->loan bounded by the price limit. The pool partial-fills
        // up to it, so a too-large delever still repays as much as the bound
        // allows.
        uint256 loanGot =
            SwapLib.swapExactInToLimit(address(yieldToken), address(loanToken), feeYieldDebt, yieldToSell, limit);

        // Cap repayment at outstanding debt
        repaid = loanGot > currentDebt ? currentDebt : loanGot;
        // slither-disable-next-line unused-return -> repay amount is known (repaid); Morpho reverts on failure
        if (repaid > 0) market.repay(repaid);
    }

    /// @dev Harvest leg of `rebalance` (internal; runs first). Realize surplus yield:
    ///      sell the yield held above what the debt needs and supply the proceeds as
    ///      collateral. NAV-neutral apart from swap costs. Add-only (no withdraw, no
    ///      borrow) — it never increases leverage, so no flash loan is needed and it
    ///      cannot push the position toward liquidation. No-op when the yield factor
    ///      `rho = yieldValue / debt` is within the band (`rho <= yieldFactorMax` — before
    ///      enough surplus accrues, or a yield depeg), or while a recovery is pending.
    ///
    ///      Both legs (yield->loan, then loan->collateral) swap under an oracle-derived
    ///      `sqrtPriceLimitX96` (`maxSlippageBps` price-impact bound): each pool
    ///      partial-fills up to its limit and the leg is skipped when the pool is
    ///      already past it, so harvest never reverts the rebalance or blocks the
    ///      delever leg. Any surplus the second leg does not convert to collateral is
    ///      repaid as debt, capped at the debt outstanding -- loan token idles only in
    ///      the extreme where the realized surplus exceeds the whole debt.
    ///
    ///      The two legs treat a partial fill differently. Leg 1's unsold surplus stays as
    ///      yield and is retried next harvest; leg 2's is one-way -- loan it cannot convert
    ///      is repaid as debt, so that round the surplus deleverages the position instead of
    ///      growing collateral. That is value-preserving (a debt paydown, NAV ~flat); the
    ///      vault is left underlevered until the health factor drifts above the band and the
    ///      lever leg re-levers. Leg 2's throughput tracks asset/debt pool depth, which
    ///      `maxTvl` bounds and which `redeemInKind` sidesteps entirely for exits.
    function _harvest() internal {
        // Frozen while a recovery is pending or executed: don't reshape the position
        // (yield -> collateral) while it is being wound down.
        if (recoveryValidAt != 0 || recovered) return;
        uint256 currentDebt = market.debt();

        uint256 yieldPrice = IOracle(yieldOracle).price();
        uint256 yieldBalance = yieldToken.balanceOf(address(this));

        // Yield needed to back the debt at oracle value; only the excess is harvestable
        // surplus. Selling just the excess keeps the yield leg's oracle value >= debt, so
        // the unwind invariant is unchanged.
        uint256 yieldForDebt = currentDebt.mulDiv(MarketLib.ORACLE_PRICE_SCALE, yieldPrice);
        // Fire only when the yield factor is above the band's upper edge: yieldBalance >
        // yieldForDebt * yieldFactorMax / WAD (equivalently rho > yieldFactorMax). Then realize
        // back down to yieldForDebt (rho = 1, bare backing).
        if (yieldBalance <= yieldForDebt.mulDiv(yieldFactorMax, MarketLib.WAD)) return;
        uint256 yieldToHarvest = yieldBalance - yieldForDebt;

        uint256 loanBefore = loanToken.balanceOf(address(this));

        // Leg 1: sell surplus yield -> loan on the yield/debt pool, bounded by an
        // oracle-derived price limit (`maxSlippageBps` of price impact). The pool
        // partial-fills up to the limit; when it is already past the bound the swap
        // is skipped. Best-effort either way -- harvest never reverts the rebalance
        // or blocks the delever leg. Same mechanism as `_rebalanceDelever`.
        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(yieldToken));
        if (!ok) return;
        uint256 loanGot =
            SwapLib.swapExactInToLimit(address(yieldToken), address(loanToken), feeYieldDebt, yieldToHarvest, limit);
        // A dust surplus (or a pool already at the bound) rounds the swap output to
        // zero; no-op rather than pass a zero amount to the next leg, which the router
        // and Morpho reject.
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing realized, skip
        if (loanGot == 0) return;

        // Leg 2: loan -> collateral on the asset/debt pool, bounded to the market oracle
        // like leg 1 -- partial-fills up to the limit, skipped when already past the bound.
        (uint160 assetLimit, bool assetOk) = _assetDebtSwapLimit();
        uint256 collateralAdded =
            assetOk ? SwapLib.swapExactInToLimit(address(loanToken), asset(), feeAssetDebt, loanGot, assetLimit) : 0;
        // Supply as collateral only — no re-lever. This raises hf; `rebalance`'s lever
        // branch redeploys the collateral if/when hf later drifts above the band.
        if (collateralAdded > 0) market.supplyCollateral(collateralAdded);

        // Repay whatever leg 2 did not convert (a partial fill, or all of it when skipped),
        // capped at the debt so it cannot over-repay; only a remainder beyond the whole
        // debt is left idle as loan.
        uint256 leftover = loanToken.balanceOf(address(this)) - loanBefore;
        uint256 toRepay = Math.min(leftover, currentDebt);
        // slither-disable-next-line unused-return -> repay amount is known (toRepay); Morpho reverts on failure
        if (toRepay > 0) market.repay(toRepay);

        emit Harvested(yieldToHarvest, collateralAdded);
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
        // slither-disable-next-line incorrect-equality -> exact-zero guard: zero yield converts to zero asset
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
        // slither-disable-next-line unused-return -> position is cleared by shares (repayAll); the repaid amount isn't needed here
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
