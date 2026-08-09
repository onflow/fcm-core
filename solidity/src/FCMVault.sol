// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "./interfaces/IFCMVault.sol";
import {IUniswapV3Pool} from "./interfaces/external/IUniswapV3Pool.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Morpho Blue singleton address for Flow EVM
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);

/// @title FCMVault
/// @author Flow Foundation
/// @notice An ERC-4626 compliant vault that executes and automates an immutable three-leg leveraged carry trade
/// strategy. Strategy Mechanics (Three-Leg Position): 1. Asset Leg: Collateral token supplied to Morpho to create
/// borrowing capacity. 2. Debt Leg: Loan token borrowed against the supplied collateral. 3. Yield Leg: Yield-bearing
/// token bought/minted using the borrowed loan token.
/// Key Operational Features: - Single Configuration: Each vault instance executes a single carry trade with immutable
/// parameters. - External Rebalancing: Exposes a external rebalance() function to adjust LTV, preserve 100% net asset
/// exposure, maximize yield spread, and keep the position clear of liquidation thresholds. - ERC-4626 Tokenized Vault:
/// Yield is auto-compounded directly into share price appreciation.
contract FCMVault is ERC4626, AccessControl, Ownable2Step, IFCMVault, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    /// @inheritdoc IFCMVault
    bytes32 public constant EARLY_ACCESS_ROLE = keccak256("EARLY_ACCESS_ROLE");
    /// @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more
    /// expensive. See
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;
    /// @dev Basis-points denominator (10_000 = 100%).
    uint256 internal constant BPS = 10_000;
    /// @dev Seconds in a year, for the time-based management fee accrual.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @dev Hard cap on the management fee (10%/yr) — admin cannot exceed.
    uint256 internal constant MAX_MANAGEMENT_FEE_BPS = 1000;
    /// @dev Hard cap on the performance fee (50%) — admin cannot exceed.
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 5000;
    /// @dev Q64.96 fixed-point one squared (`2**192`), used to build the `sqrtPriceX96` price limit for rebalance
    /// swaps.
    uint256 internal constant ONE_X192 = 1 << 192;
    /// @dev Uniswap V3 tick-math bounds on a valid `sqrtPriceLimitX96`. A limit outside `(MIN_SQRT_RATIO,
    /// MAX_SQRT_RATIO)` is rejected by the pool; the vault treats such a limit as "no feasible swap" and skips.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IERC20 public immutable LOAN_TOKEN;
    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IERC20 public immutable YIELD_TOKEN;
    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    uint24 public immutable FEE_YIELD_DEBT;
    /// @inheritdoc IFCMVault
    address public immutable YIELD_DEBT_POOL;
    /// @inheritdoc IFCMVault
    uint24 public immutable FEE_ASSET_DEBT;
    /// @inheritdoc IFCMVault
    address public immutable ASSET_DEBT_POOL;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MIN;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MAX;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MIN_TARGET;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MAX_TARGET;
    /// @inheritdoc IFCMVault
    uint256 public immutable YIELD_FACTOR_MAX;
    /// @inheritdoc IFCMVault
    address public immutable YIELD_ORACLE;

    // -- Timelocked emergency recovery (custodial, in-kind) ------------------
    /// @inheritdoc IFCMVault
    uint256 public immutable RECOVERY_DELAY;
    /// @inheritdoc IFCMVault
    uint256 public recoveryValidAt;
    /// @inheritdoc IFCMVault
    bool public recovered;

    /// @inheritdoc IFCMVault
    MarketParams public market;
    /// @inheritdoc IFCMVault
    uint256 public maxTvl;
    /// @inheritdoc IFCMVault
    uint256 public maxSlippageBps;

    // -- Management & performance fees ---------------------------------------
    /// @inheritdoc IFCMVault
    uint256 public managementFeeBps;
    /// @inheritdoc IFCMVault
    uint256 public performanceFeeBps;
    /// @inheritdoc IFCMVault
    address public feeRecipient;
    /// @inheritdoc IFCMVault
    uint256 public lastFeeAccrual;
    /// @inheritdoc IFCMVault
    uint256 public perfHighWaterMark;

    /// @dev Emits a `VaultState` snapshot after the wrapped function body runs. Placed after `_;` so the event reflects
    /// post-call state. Modifying entry points accrue market interest before mutating, so the debt read here is fresh.
    modifier logsVaultState() {
        _;
        _logVaultState();
    }

    constructor(InitParams memory p) ERC20(p.name, p.symbol) ERC4626(p.collateral) Ownable(p.admin) {
        require(p.healthFactorMin >= MarketLib.WAD, BelowMinWad(p.healthFactorMin));
        require(
            p.healthFactorMin <= p.healthFactorMinTarget,
            InvalidHealthFactorBounds(p.healthFactorMin, p.healthFactorMinTarget)
        );
        require(
            p.healthFactorMinTarget <= p.healthFactorMaxTarget,
            InvalidHealthFactorBounds(p.healthFactorMinTarget, p.healthFactorMaxTarget)
        );
        require(
            p.healthFactorMaxTarget <= p.healthFactorMax,
            InvalidHealthFactorBounds(p.healthFactorMaxTarget, p.healthFactorMax)
        );
        require(p.yieldFactorMax >= MarketLib.WAD, BelowMinWad(p.yieldFactorMax));
        require(p.yieldDebtPool != address(0), ZeroAddress());
        require(p.assetDebtPool != address(0), ZeroAddress());

        LOAN_TOKEN = p.loanToken;
        YIELD_TOKEN = p.yieldToken;
        FEE_YIELD_DEBT = p.feeYieldDebt;
        FEE_ASSET_DEBT = p.feeAssetDebt;
        YIELD_DEBT_POOL = p.yieldDebtPool;
        ASSET_DEBT_POOL = p.assetDebtPool;
        HEALTH_FACTOR_MIN = p.healthFactorMin;
        HEALTH_FACTOR_MAX = p.healthFactorMax;
        HEALTH_FACTOR_MIN_TARGET = p.healthFactorMinTarget;
        HEALTH_FACTOR_MAX_TARGET = p.healthFactorMaxTarget;
        YIELD_FACTOR_MAX = p.yieldFactorMax;
        YIELD_ORACLE = p.yieldOracle;

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

        RECOVERY_DELAY = p.recoveryDelay;
        maxSlippageBps = 100; // 1% default; admin retunes per pool depth.

        lastFeeAccrual = block.timestamp;
        // Seed the HWM at the starting price-per-share so the first deposit isn't counted as performance.
        perfHighWaterMark = MarketLib.WAD / (10 ** DECIMALS_OFFSET);

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
    }

    /// @inheritdoc IFCMVault
    function setMaxSlippageBps(uint256 newBps) external onlyOwner {
        if (newBps >= BPS) revert InvalidSlippage();
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setManagementFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_MANAGEMENT_FEE_BPS) revert InvalidFee();
        // slither-disable-next-line reentrancy-no-eth
        _accrueFees();
        emit ManagementFeeSet(managementFeeBps, newBps);
        managementFeeBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setPerformanceFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_PERFORMANCE_FEE_BPS) revert InvalidFee();
        // slither-disable-next-line reentrancy-no-eth
        _accrueFees();
        emit PerformanceFeeSet(performanceFeeBps, newBps);
        performanceFeeBps = newBps;
    }

    // slither-disable-next-line reentrancy-no-eth -> onlyOwner modifier
    /// @inheritdoc IFCMVault
    function setFeeRecipient(address newRecipient) external onlyOwner {
        // slither-disable-next-line reentrancy-no-eth
        _accrueFees();
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @inheritdoc IFCMVault
    function accrueFees() external {
        _accrueFees();
    }

    /// @inheritdoc IFCMVault
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

    /// @inheritdoc IFCMVault
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @inheritdoc IFCMVault
    function scheduleEmergencyRecovery() external onlyOwner {
        recoveryValidAt = block.timestamp + RECOVERY_DELAY;
        emit EmergencyRecoveryScheduled(msg.sender, recoveryValidAt);
    }

    /// @inheritdoc IFCMVault
    function cancelEmergencyRecovery() external onlyOwner {
        recoveryValidAt = 0;
        emit EmergencyRecoveryCancelled(msg.sender);
    }

    /// @inheritdoc IFCMVault
    function executeEmergencyRecovery() external onlyOwner {
        // comparing with timestamp is safe because the recovery is scheduled hours/days in the future and
        // the function is onlyOwner
        // forge-lint: disable-next-line(block-timestamp)
        if (recoveryValidAt == 0 || block.timestamp < recoveryValidAt) {
            revert EmergencyRecoveryNotReady();
        }
        recoveryValidAt = 0;
        recovered = true;

        market.accrueInterest();

        // Owner funds the full debt; repay by shares so the position zeros exactly.
        uint256 debtRepaid = market.debt();
        LOAN_TOKEN.safeTransferFrom(msg.sender, address(this), debtRepaid);
        // slither-disable-next-line unused-return -> position is cleared by shares (repayAll);
        market.repayAll();

        // Free all collateral now that the debt is cleared.
        uint256 collateralOut = market.collateral();
        if (collateralOut > 0) market.withdrawCollateral(collateralOut);

        // Sweep everything to the owner, in kind.
        address to = owner();
        uint256 yieldOut = YIELD_TOKEN.balanceOf(address(this));
        uint256 loanOut = LOAN_TOKEN.balanceOf(address(this)); // over-funded remainder
        if (collateralOut > 0) IERC20(asset()).safeTransfer(to, collateralOut);
        if (yieldOut > 0) YIELD_TOKEN.safeTransfer(to, yieldOut);
        if (loanOut > 0) LOAN_TOKEN.safeTransfer(to, loanOut);

        emit EmergencyRecoveryExecuted(debtRepaid, collateralOut, yieldOut, loanOut);
    }

    /// @inheritdoc IFCMVault
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
        // the caller supplies the LOAN_TOKEN, so no swap is needed.
        uint256 debtRepaid = market.debt().mulDiv(shares, claims, Math.Rounding.Ceil);
        if (debtRepaid > 0) {
            LOAN_TOKEN.safeTransferFrom(msg.sender, address(this), debtRepaid);
            // slither-disable-next-line unused-return -> repay amount is known (debtRepaid); Morpho reverts on failure
            market.repay(debtRepaid);
        }

        // Pro-rata collateral + yield, delivered in kind (rounded down).
        collateralOut = market.collateral().mulDiv(shares, claims);
        yieldOut = YIELD_TOKEN.balanceOf(address(this)).mulDiv(shares, claims);

        _burn(owner, shares);

        if (collateralOut > 0) {
            market.withdrawCollateral(collateralOut);
            IERC20(asset()).safeTransfer(receiver, collateralOut);
        }
        if (yieldOut > 0) YIELD_TOKEN.safeTransfer(receiver, yieldOut);

        emit RedeemInKind(msg.sender, receiver, owner, shares, debtRepaid, collateralOut, yieldOut);
    }

    /// @inheritdoc IFCMVault
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IFCMVault)
        logsVaultState
        returns (uint256 shares)
    {
        // Freeze deposits while a recovery is pending (recoveryValidAt != 0) or done
        // (recovered) — don't let new funds in ahead of a sweep. Redeems stay open.
        if (recoveryValidAt != 0 || recovered) revert EmergencyRecoveryActive();
        // Accrue fees first so the deposit prices in at the post-fee share price.
        _accrueFees();

        uint256 navBefore = totalAssets();
        // Don't mint against a zero NAV while shares exist: the `navBefore + 1` denominator
        // below would collapse and mint a disproportionate amount. Empty-vault first deposits
        // (totalSupply() == 0) are unaffected.
        // slither-disable-next-line incorrect-equality -> exact-zero is the intended guard (totalAssets clamps to 0)
        if (navBefore == 0 && totalSupply() > 0) revert VaultUnderwater();
        if (navBefore + assets > maxTvl) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            // slither-disable-next-line unused-return -> swap output is measured via the totalAssets() delta below
            SwapLib.swapExactIn(address(LOAN_TOKEN), address(YIELD_TOKEN), FEE_YIELD_DEBT, toBorrow);
        }

        // the depositor's contribution to NAV, denominated in outer vault assets
        uint256 contributed = totalAssets() - navBefore;
        // mint shares in proportion to the depositor's contribution
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1); // +1 rounds in favour of the vaults
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IFCMVault
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IFCMVault)
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

    /// @inheritdoc IFCMVault
    function maxDeposit(address receiver) public view override(ERC4626, IFCMVault) returns (uint256) {
        // The emergency recovery deposit freeze is enforced by the guard in deposit();
        // maxDeposit mirrors it as 0 because ERC-4626 requires reporting 0 when deposits
        // are disabled.
        if (recoveryValidAt != 0 || recovered) return 0;
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        uint256 cachedTotalAssets = totalAssets();
        // Mirror the deposit() underwater guard: 0 when marked underwater with holders.
        // slither-disable-next-line incorrect-equality -> exact-zero is the intended guard (totalAssets clamps to 0)
        if (cachedTotalAssets == 0 && totalSupply() > 0) return 0;
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @inheritdoc IFCMVault
    function totalAssets() public view override(ERC4626, IFCMVault) returns (uint256) {
        uint256 assetAmount = market.collateral();
        uint256 yieldInAsset = _yieldToAsset(YIELD_TOKEN.balanceOf(address(this)));
        uint256 debtInAsset = market.debtToCollateral(market.debt());
        uint256 gross = assetAmount + yieldInAsset;
        if (gross > debtInAsset) {
            return gross - debtInAsset;
        }
        return 0;
    }

    /// @inheritdoc IFCMVault
    function mint(uint256, address) public pure override(ERC4626, IFCMVault) returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function withdraw(uint256, address, address) public pure override(ERC4626, IFCMVault) returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function maxMint(address) public pure override(ERC4626, IFCMVault) returns (uint256) {
        return 0;
    }

    /// @inheritdoc IFCMVault
    function maxWithdraw(address) public pure override(ERC4626, IFCMVault) returns (uint256) {
        return 0;
    }

    /// @dev Unwind a slice of the vault's position,
    /// @notice Unwind a pro-rata slice of the vault's three-leg position for a redeem.
    /// @dev anchored on `p = shares / _totalClaims()` and the realized AMM execution price on the yield leg.
    ///
    /// Step 1 — yield leg (always full pro-rata): Sell exactly `p × YIELD_TOKEN.balanceOf(vault)` for LOAN_TOKEN on
    /// the yield/debt pool. Let `loanGot` be the LOAN_TOKEN received from this swap (measured as a balance delta so any
    /// preexisting LOAN_TOKEN dust is not credited to this redeem).
    /// Step 2 — branch on realized execution vs. pro-rata debt slice `d* = p × debt`:
    ///
    /// Case A (`loanGot ≥ d*`, fair or favorable execution): a. Repay exactly `d*` to Morpho. b. Withdraw exactly `p
    /// × collateral` of the asset from Morpho. c. Reconcile the surplus `loanGot - d*` LOAN_TOKEN to the asset on the
    /// asset/debt pool. Surplus is real economic value (yield leg outgrew the debt leg) and accrues to the redeemer.
    /// Case B (`loanGot < d*`, yield underperformed at the AMM): a. Flash-borrow the shortfall `d* - loanGot` in
    /// LOAN_TOKEN from Morpho, so the vault holds the full `d*`. b. Repay the full `d*` to Morpho, then withdraw the
    /// full `p × collateral`. Repaying before withdrawing makes the withdrawal health-factor-neutral, so it is
    /// permitted at any health factor (see `onMorphoFlashLoan`). c. Sell just enough of the withdrawn collateral back
    /// to LOAN_TOKEN to repay the flash. The redeemer takes home their full pro-rata value; the collateral sold covers
    /// the debt the yield leg could not. No surplus reconcile leg runs in this case.
    /// Rounding favors the vault: pro-rata slices are computed with mulDiv rounding down.
    /// @param shares Vault shares being redeemed (numerator of `p`).
    function _unwindSlice(uint256 shares) internal {
        uint256 claims = _totalClaims();

        // yieldOut is the quantity of yield tokens we are selling to satisfy the redemption
        uint256 yieldOut = YIELD_TOKEN.balanceOf(address(this)).mulDiv(shares, claims);
        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));
        if (yieldOut > 0) {
            // slither-disable-next-line unused-return -> loanGot is measured from the loanToken balance delta below
            SwapLib.swapExactIn(address(YIELD_TOKEN), address(LOAN_TOKEN), FEE_YIELD_DEBT, yieldOut);
        }
        uint256 loanGot = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;

        uint256 debtSlice = market.debt().mulDiv(shares, claims);
        uint256 collSlice = market.collateral().mulDiv(shares, claims);

        if (loanGot >= debtSlice) {
            // Case A: full pro-rata unwind, reconcile surplus to the asset.
            // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
            if (debtSlice > 0) market.repay(debtSlice);
            if (collSlice > 0) market.withdrawCollateral(collSlice);
            uint256 surplus = loanGot - debtSlice;
            if (surplus > 0) {
                // slither-disable-next-line unused-return -> surplus-swap output is captured by the redeem balance
                SwapLib.swapExactIn(address(LOAN_TOKEN), asset(), FEE_ASSET_DEBT, surplus);
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
            MORPHO.flashLoan(address(LOAN_TOKEN), debtSlice - loanGot, abi.encode(debtSlice, collSlice));
        }
    }

    /* solhint-disable ordering, morpho callback basically internal*/
    /// @notice Morpho flash-loan callback for redeem's Case-B path. Only callable by Morpho, which only invokes it when
    /// the vault itself initiated the flash loan (Morpho calls back the caller of `flashLoan`).
    /// @dev On entry the vault
    /// holds `loanGot` (from the yield sale) plus the flash-borrowed `shortfall`, together the full pro-rata
    /// `debtSlice`. Repay the slice, withdraw the redeemer's full `collSlice`, then sell exactly `shortfall` of it back
    /// to loan token to repay the flash. The unsold collateral stays as the vault's asset balance and is delivered to
    /// the redeemer by `redeem`. Reverts if the redeemer's own collateral slice cannot cover the shortfall (genuinely
    /// underwater).
    /// @param shortfall Loan-token amount flash-borrowed to cover the debt gap.
    /// @param data ABI-encoded `(debtSlice, collSlice)` from `_unwindSlice`.
    function onMorphoFlashLoan(uint256 shortfall, bytes calldata data) external {
        require(msg.sender == address(MORPHO), Unauthorized());
        (uint256 debtSlice, uint256 collSlice) = abi.decode(data, (uint256, uint256));

        // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
        market.repay(debtSlice);
        market.withdrawCollateral(collSlice);
        // Sell collateral for exactly `shortfall` loan token to repay the flash,
        // spending at most the withdrawn slice; the rest stays for the redeemer.
        // slither-disable-next-line unused-return -> collateral spent is captured by the redeem balance delta
        SwapLib.swapExactOut(asset(), address(LOAN_TOKEN), FEE_ASSET_DEBT, shortfall, collSlice);
    }

    /* solhint-enable ordering */

    /// @dev Leverage leg of `rebalance`, rebalancing only to the re-entry target just inside the nearest bound rather
    /// than to a central target. - If `hf ∈ [HEALTH_FACTOR_MIN, HEALTH_FACTOR_MAX]`, the call is a no-op. - If `hf >
    /// HEALTH_FACTOR_MAX`, the position is under-levered: borrow exactly `addDebt = (maxBorrow / maxTarget) - debt` of
    /// the loan token and swap it to the yield token, landing HF at `HEALTH_FACTOR_MAX_TARGET` (just below the upper
    /// bound). - If `hf < HEALTH_FACTOR_MIN`, the position is over-levered: sell exactly enough yield token to repay
    /// `repayAmount = debt - (maxBorrow / minTarget)` of debt, landing HF at `HEALTH_FACTOR_MIN_TARGET` (just above the
    /// lower bound).
    /// Rebalancing to the re-entry target nearest the breached bound minimizes swap volume per rebalance. Swap cost is
    /// price impact plus pool fees - both are proportional to swap volume. So, the smallest swap that restores health
    /// within the band incurs the lowest average-case cost. By convention, there is a small buffer between the band's
    /// bound and the target.
    /// Partial rebalancing: the rebalance swap carries a `sqrtPriceLimitX96` derived from the oracle price and
    /// `maxSlippageBps` (see `_yieldDebtSwapLimit`). If reaching the re-entry target would push the pool past that
    /// price, the pool fills as much as possible without reverting.
    /// Note the bound is on the pool's *marginal price* relative to the oracle, i.e. on price impact. The pool's fixed
    /// LP fee is a separate, known cost and is not part of this bound.
    function _adjustLeverage() internal {
        uint256 currentDebt = market.debt();
        uint256 maxBorrow = market.maxBorrow(); // independent of current debt balance
        // we compute inline here rather than use MarketLib.healthFactor to save a SLOAD
        uint256 hfBefore = currentDebt == 0 ? type(uint256).max : maxBorrow.mulDiv(MarketLib.WAD, currentDebt);

        // slither-disable-next-line incorrect-equality -> exact-zero is the intended "no recovery pending" guard
        if (hfBefore > HEALTH_FACTOR_MAX && recoveryValidAt == 0) {
            // Lever-up is frozen while an emergency recovery is pending: the position
            // is slated for in-kind wind-down, so re-levering (more debt + AMM cost)
            // would work against it. Delever stays live — it only de-risks — matching
            // `_harvest`'s recovery gate. Cancelling recovery (`recoveryValidAt = 0`)
            // restores lever-up immediately.
            _rebalanceLever(maxBorrow, currentDebt);
        } else if (hfBefore < HEALTH_FACTOR_MIN) {
            _rebalanceDelever(maxBorrow, currentDebt);
        } else {
            // Inside the dead band, or lever-up suppressed during a pending recovery.
            return;
        }

        emit Rebalanced(msg.sender, hfBefore, market.healthFactor());
    }

    /// @notice Lever-up branch of `rebalance`: position is under-levered (`hf > HEALTH_FACTOR_MAX`). Borrow exactly the
    /// debt slice that lands the position at `HEALTH_FACTOR_MAX_TARGET` and swap it into yield token.
    /// @dev `targetDebt =
    /// maxBorrow * WAD / HEALTH_FACTOR_MAX_TARGET` is the debt level that, against the current collateral, produces an
    /// HF of exactly `HEALTH_FACTOR_MAX_TARGET` (just below the upper bound). Since `hf > max >= maxTarget`,
    /// `currentDebt <
    /// targetDebt`. The borrow leg adds `targetDebt - currentDebt`.
    ///
    /// Partial: the full `borrowAmount` is borrowed up front, then the loan->yield swap runs under a
    /// `sqrtPriceLimitX96` derived from the oracle and `maxSlippageBps`. If the swap would push the pool past that
    /// price, the pool fills only up to it (a partial fill) and the unspent loan token is immediately repaid, so the
    /// position lands partway to `HEALTH_FACTOR_MAX_TARGET` with no idle loan token left behind. Borrowing first and
    /// repaying the remainder (rather than sizing the borrow to the fill) avoids needing the swap output before the
    /// tokens to swap exist. When the pool is already priced past the bound, the swap is skipped and the borrow is
    /// fully repaid (no-op).
    /// @param maxBorrow Current maximum-borrowable amount at LLTV (independent of current debt)
    /// @param currentDebt Current outstanding debt (caller passes the same value used to compute `hfBefore` to avoid a
    /// second `MORPHO.position` SLOAD).
    /// @return additionalDebt Net new debt taken on in this call (the loan token
    /// actually swapped into yield; 0 if nothing filled).
    function _rebalanceLever(uint256 maxBorrow, uint256 currentDebt) internal returns (uint256 additionalDebt) {
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, HEALTH_FACTOR_MAX_TARGET);
        if (targetDebt <= currentDebt) return 0;
        uint256 borrowAmount = targetDebt - currentDebt;

        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(LOAN_TOKEN));
        if (!ok) return 0; // pool already past the slippage bound — no-op.

        // Borrow first, then swap loan->yield bounded by the price limit. The
        // pool partial-fills up to the limit; whatever loan it does not consume
        // stays with the vault and is repaid below, so we only lever by the
        // amount actually converted to yield.
        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));
        market.borrow(borrowAmount);
        // slither-disable-next-line unused-return -> levered amount is measured via the loanToken balance delta below
        SwapLib.swapExactInToLimit(address(LOAN_TOKEN), address(YIELD_TOKEN), FEE_YIELD_DEBT, borrowAmount, limit);

        // Repay the loan token the swap left behind, so no idle loan lingers.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
        if (leftover > 0) market.repay(leftover);
        additionalDebt = borrowAmount - leftover;
    }

    /// @notice Delever branch of `rebalance`: position is over-levered (`hf < HEALTH_FACTOR_MIN`). Sell yield token for
    /// loan token to repay enough debt to land the position back at `HEALTH_FACTOR_MIN_TARGET`.
    /// @dev Sizing: targetDebt
    /// = maxBorrow * WAD / HEALTH_FACTOR_MIN_TARGET repayAmount   = currentDebt - targetDebt yieldToSell   =
    /// repayAmount * 1e36 / yieldOraclePrice
    ///
    /// `yieldToSell` is the oracle-implied yield amount whose loan-token value equals `repayAmount`. AMM slippage shows
    /// up as a small under-shoot (post-rebalance HF is slightly below `HEALTH_FACTOR_MIN_TARGET` if the swap realized
    /// less than oracle).
    /// Partial: the yield->loan swap runs under a `sqrtPriceLimitX96` derived from the oracle and `maxSlippageBps`. If
    /// selling the full `yieldToSell` would push the pool past that price, the pool fills only up to it and the vault
    /// repays just the realized loan token, so the position lands partway to `HEALTH_FACTOR_MIN_TARGET` rather than
    /// reverting. When the pool is already priced past the bound the swap is skipped entirely (no-op).
    /// @param maxBorrow Current maximum-borrowable amount at LLTV (may be 0 after a liquidation that wiped collateral).
    /// @param currentDebt Current outstanding debt.
    /// @return repaid Amount of loan token repaid to Morpho in this call.
    function _rebalanceDelever(uint256 maxBorrow, uint256 currentDebt) internal returns (uint256 repaid) {
        // conceptually, target debt is maxBorrow / HEALTH_FACTOR_MIN_TARGET
        uint256 targetDebt = maxBorrow.mulDiv(MarketLib.WAD, HEALTH_FACTOR_MIN_TARGET);
        if (targetDebt >= currentDebt) return 0;
        uint256 repayAmount = currentDebt - targetDebt;

        uint256 yieldPrice = IOracle(YIELD_ORACLE).price();
        // Oracle-implied yield amount whose loan-token value equals
        // `repayAmount` (not accounting for slippage)
        uint256 yieldToSell = repayAmount.mulDiv(MarketLib.ORACLE_PRICE_SCALE, yieldPrice);

        uint256 yieldBalance = YIELD_TOKEN.balanceOf(address(this));
        if (yieldToSell > yieldBalance) yieldToSell = yieldBalance;
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing to sell, so skip the swap
        if (yieldToSell == 0) return 0;

        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(YIELD_TOKEN));
        if (!ok) return 0; // pool already past the slippage bound — no-op.

        // Sell yield->loan bounded by the price limit. The pool partial-fills
        // up to it, so a too-large delever still repays as much as the bound
        // allows.
        uint256 loanGot =
            SwapLib.swapExactInToLimit(address(YIELD_TOKEN), address(LOAN_TOKEN), FEE_YIELD_DEBT, yieldToSell, limit);

        // Cap repayment at outstanding debt
        repaid = loanGot > currentDebt ? currentDebt : loanGot;
        // slither-disable-next-line unused-return -> repay amount is known (repaid); Morpho reverts on failure
        if (repaid > 0) market.repay(repaid);
    }

    /// @dev Harvest leg of `rebalance` (internal; runs first). Realize surplus yield: sell the yield held above what
    /// the debt needs and supply the proceeds as collateral. NAV-neutral apart from swap costs. Add-only (no withdraw,
    /// no borrow) — it never increases leverage, so no flash loan is needed and it cannot push the position toward
    /// liquidation. No-op when the yield factor `rho = yieldValue / debt` is within the band (`rho <= YIELD_FACTOR_MAX`
    /// — before enough surplus accrues, or a yield depeg), or while a recovery is pending.
    /// Both legs (yield->loan, then loan->collateral) swap under an oracle-derived `sqrtPriceLimitX96`
    /// (`maxSlippageBps` price-impact bound): each pool partial-fills up to its limit and the leg is skipped when the
    /// pool is already past it, so harvest never reverts the rebalance or blocks the delever leg. Any surplus the
    /// second leg does not convert to collateral is repaid as debt, capped at the debt outstanding -- loan token idles
    /// only in the extreme where the realized surplus exceeds the whole debt.
    /// The two legs treat a partial fill differently. Leg 1's unsold surplus stays as yield and is retried next
    /// harvest; leg 2's is one-way -- loan it cannot convert is repaid as debt, so that round the surplus deleverages
    /// the position instead of growing collateral. That is value-preserving (a debt paydown, NAV ~flat); the vault is
    /// left underlevered until the health factor drifts above the band and the lever leg re-levers. Leg 2's throughput
    /// tracks asset/debt pool depth, which `maxTvl` bounds and which `redeemInKind` sidesteps entirely for exits.
    function _harvest() internal {
        // Frozen while a recovery is pending or executed: don't reshape the position
        // (yield -> collateral) while it is being wound down.
        if (recoveryValidAt != 0 || recovered) return;
        uint256 currentDebt = market.debt();

        uint256 yieldPrice = IOracle(YIELD_ORACLE).price();
        uint256 yieldBalance = YIELD_TOKEN.balanceOf(address(this));

        // Yield needed to back the debt at oracle value; only the excess is harvestable
        // surplus. Selling just the excess keeps the yield leg's oracle value >= debt, so
        // the unwind invariant is unchanged.
        uint256 yieldForDebt = currentDebt.mulDiv(MarketLib.ORACLE_PRICE_SCALE, yieldPrice);
        // Fire only when the yield factor is above the band's upper edge: yieldBalance >
        // yieldForDebt * YIELD_FACTOR_MAX / WAD (equivalently rho > YIELD_FACTOR_MAX). Then realize
        // back down to yieldForDebt (rho = 1, bare backing).
        if (yieldBalance <= yieldForDebt.mulDiv(YIELD_FACTOR_MAX, MarketLib.WAD)) return;
        uint256 yieldToHarvest = yieldBalance - yieldForDebt;

        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));

        // Leg 1: sell surplus yield -> loan on the yield/debt pool, bounded by an
        // oracle-derived price limit (`maxSlippageBps` of price impact). The pool
        // partial-fills up to the limit; when it is already past the bound the swap
        // is skipped. Best-effort either way -- harvest never reverts the rebalance
        // or blocks the delever leg. Same mechanism as `_rebalanceDelever`.
        (uint160 limit, bool ok) = _yieldDebtSwapLimit(address(YIELD_TOKEN));
        if (!ok) return;
        uint256 loanGot = SwapLib.swapExactInToLimit(
            address(YIELD_TOKEN), address(LOAN_TOKEN), FEE_YIELD_DEBT, yieldToHarvest, limit
        );
        // A dust surplus (or a pool already at the bound) rounds the swap output to
        // zero; no-op rather than pass a zero amount to the next leg, which the router
        // and Morpho reject.
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing realized, skip
        if (loanGot == 0) return;

        // Leg 2: loan -> collateral on the asset/debt pool, bounded to the market oracle
        // like leg 1 -- partial-fills up to the limit, skipped when already past the bound.
        (uint160 assetLimit, bool assetOk) = _assetDebtSwapLimit();
        uint256 collateralAdded =
            assetOk ? SwapLib.swapExactInToLimit(address(LOAN_TOKEN), asset(), FEE_ASSET_DEBT, loanGot, assetLimit) : 0;
        // Supply as collateral only — no re-lever. This raises hf; `rebalance`'s lever
        // branch redeploys the collateral if/when hf later drifts above the band.
        if (collateralAdded > 0) market.supplyCollateral(collateralAdded);

        // Repay whatever leg 2 did not convert (a partial fill, or all of it when skipped),
        // capped at the debt so it cannot over-repay; only a remainder beyond the whole
        // debt is left idle as loan.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        uint256 toRepay = Math.min(leftover, currentDebt);
        // slither-disable-next-line unused-return -> repay amount is known (toRepay); Morpho reverts on failure
        if (toRepay > 0) market.repay(toRepay);

        emit Harvested(yieldToHarvest, collateralAdded);
    }

    /// @dev The health factor `deposit` levers fresh collateral toward: the midpoint of the rebalance band. `rebalance`
    /// only acts at the band's edges, so deposits aim for the center to leave symmetric headroom in both directions
    /// before the position drifts to a bound and triggers a rebalance.
    function _depositTargetHf() internal view returns (uint256) {
        return (HEALTH_FACTOR_MIN + HEALTH_FACTOR_MAX) / 2;
    }

    /// @dev How much loan token to borrow against `newAssets` while keeping the position at the deposit-target HF
    /// (`_depositTargetHf`, the band midpoint). Returns the smaller of two caps: - `capFromNewAsset`: the borrow
    /// `newAssets` of fresh collateral could support on its own at the target HF. - `capFromTargetDebt`: the additional
    /// borrow that, combined with existing debt and existing collateral, would land the whole position at the target
    /// HF.
    /// Taking the min means each deposit borrows at most its own proportional share of headroom: small deposits cannot
    /// rebalance an over-collateralized protocol back to target, and no deposit can push an already-too-leveraged
    /// position past the target HF (`capFromTargetDebt` clamps to 0 in that case).
    /// Protocol-wide rebalancing (driving the whole position back inside the band regardless of new asset size) is the
    /// job of `rebalance`, not `deposit`.
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
        return yieldAmount.mulDiv(IOracle(YIELD_ORACLE).price(), market.oraclePrice());
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn). - Mint (`from == 0`): the receiver must be
    /// allowlisted. - Transfer (both non-zero): both sender and receiver must be allowlisted. - Burn (`to == 0`):
    /// always allowed, preserving the exit path for de-allowlisted holders.
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

    /// @notice Resolve the `sqrtPriceLimitX96` and a go/skip flag for a swap selling `tokenIn` for `tokenOut` on
    /// `pool`, bounding price impact to `maxSlippageBps` away from a fair rate of `outPerInNum / outPerInDen`
    /// (`tokenOut` per `tokenIn`, with token decimals already baked into the fraction). Pure Uniswap-price math: it
    /// does not know or care which token is the loan/oracle side.
    /// @dev The pool price is `token1/token0` (token0 = the
    /// lower-address token). The fair rate is mapped to that coordinate and discounted toward the side the swap moves
    /// it: selling token0 (`zeroForOne`) drives the price down (limit below spot), selling token1 drives it up (limit
    /// above spot). The pool then fills only while its marginal price is on the good side of the limit, so the realized
    /// average price is bounded by `maxSlippageBps` of price impact relative to the fair rate.
    ///
    /// `ok` is false when the limit is out of tick-math range, or when the pool's live marginal price is already on the
    /// bad side of it (any swap would no-op or revert `SPL`) — the caller then skips.
    /// @param pool The Uniswap V3 pool
    /// for the `tokenIn`/`tokenOut` pair.
    /// @param tokenIn The token the swap sells.
    /// @param tokenOut The token the swap buys.
    /// @param outPerInNum Numerator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @param outPerInDen Denominator of the fair `tokenOut`-per-`tokenIn` rate.
    /// @return limit The Q64.96 price limit to pass to the pool.
    /// @return ok Whether a swap should be attempted.
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

        // casting to 'uint160' is safe because MAX_SQRT_RATIO is uint160 and raw is smaller.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(raw), true);
    }

    /// @dev Price limit for a swap on the yield/debt pool (rebalance lever/delever and harvest leg 1). The yield oracle
    /// quotes loan per yield token, 1e36-scaled.
    function _yieldDebtSwapLimit(address tokenIn) internal view returns (uint160, bool) {
        uint256 loanPerYield = IOracle(YIELD_ORACLE).price();
        return tokenIn == address(YIELD_TOKEN)
            ? _swapLimit(YIELD_DEBT_POOL, tokenIn, address(LOAN_TOKEN), loanPerYield, MarketLib.ORACLE_PRICE_SCALE)
            : _swapLimit(YIELD_DEBT_POOL, tokenIn, address(YIELD_TOKEN), MarketLib.ORACLE_PRICE_SCALE, loanPerYield);
    }

    /// @dev Price limit for harvest leg 2's loan->collateral swap on the asset/debt pool. The market oracle quotes loan
    /// per collateral, 1e36-scaled.
    function _assetDebtSwapLimit() internal view returns (uint160, bool) {
        return
            _swapLimit(
                ASSET_DEBT_POOL, address(LOAN_TOKEN), asset(), MarketLib.ORACLE_PRICE_SCALE, market.oraclePrice()
            );
    }

    /// @dev Accrue management + performance fees and mint the corresponding shares to `feeRecipient` (dilution — no
    /// assets leave the vault). Always accrues market interest first so NAV is fresh. No-ops once `recovered`. Skips
    /// minting (never reverts) when the recipient is unset or not allowlisted, so core flows can't be bricked.
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

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more
    // expensive. See
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function _logVaultState() internal {
        emit VaultState(
            market.collateral(),
            market.debt(),
            YIELD_TOKEN.balanceOf(address(this)),
            market.oraclePrice(),
            MarketLib.ORACLE_PRICE_SCALE,
            IOracle(YIELD_ORACLE).price()
        );
    }
}
