// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "./interfaces/IFCMVault.sol";
import {ISwapRouter02} from "./interfaces/external/ISwapRouter02.sol";
import {FeesLib} from "./libraries/FeesLib.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {MorphoLib} from "./libraries/MorphoLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FCMVault
/// @author Flow Foundation
/// @notice An ERC-4626 compliant vault that executes and automates an immutable three-leg leveraged carry trade
/// strategy.
///
/// Strategy Mechanics (Three-Leg Position):
/// 1. Collateral Leg: Collateral token supplied to Morpho to create borrowing capacity.
/// 2. Debt Leg: Loan token borrowed against the supplied collateral.
/// 3. Yield Leg: Yield-bearing token bought/minted using the borrowed loan token.
///
/// Key Operational Features:
/// - Single Configuration: Each vault instance executes a single carry trade with immutable parameters.
/// - External Rebalancing: Exposes a external rebalance() function to adjust LTV, preserve 100% net collateral
/// exposure, maximize yield spread, and keep the position clear of liquidation thresholds.
/// - ERC-4626 Tokenized Vault: Yield is auto-compounded directly into share price appreciation.
contract FCMVault is IFCMVault, ERC20, Ownable2Step, ReentrancyGuard, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MorphoLib for IMorpho;
    using MarketLib for MarketParams;

    /// @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more
    /// expensive. See
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Hard cap on the management fee (10%/yr) - owner cannot exceed.
    uint256 internal constant MAX_MANAGEMENT_FEE_BPS = 1000;
    /// @dev Hard cap on the performance fee (50%) - owner cannot exceed.
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 5000;
    /// @dev Hard cap on the maxSlippageBps (10%) - owner cannot exceed.
    uint256 internal constant MAX_SLIPPAGE_BPS = 1000;
    /// @inheritdoc IFCMVault
    uint32 public constant EMERGENCY_RECOVERY_DELAY = 7 days;

    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IERC20 public immutable COLLATERAL_TOKEN;
    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IERC20 public immutable LOAN_TOKEN;
    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IERC20 public immutable YIELD_TOKEN;

    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MIN;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MIN_TARGET;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MAX;
    /// @inheritdoc IFCMVault
    uint256 public immutable HEALTH_FACTOR_MAX_TARGET;
    /// @inheritdoc IFCMVault
    uint256 public immutable YIELD_FACTOR_MAX;

    /// @inheritdoc IFCMVault
    ISwapRouter02 public immutable SWAP_ROUTER;
    /// @inheritdoc IFCMVault
    address public immutable COLLATERAL_LOAN_POOL;
    /// @inheritdoc IFCMVault
    uint24 public immutable COLLATERAL_LOAN_POOL_FEE;
    /// @inheritdoc IFCMVault
    address public immutable YIELD_LOAN_POOL;
    /// @inheritdoc IFCMVault
    uint24 public immutable YIELD_LOAN_POOL_FEE;

    /// @inheritdoc IFCMVault
    /// @custom:security non-reentrant
    IMorpho public immutable MORPHO;
    /// @inheritdoc IFCMVault
    address public immutable MARKET_ORACLE;
    /// @inheritdoc IFCMVault
    address public immutable MARKET_IRM;
    /// @inheritdoc IFCMVault
    uint256 public immutable MARKET_LLTV;
    /// @inheritdoc IFCMVault
    IOracle public immutable YIELD_ORACLE;

    /// @inheritdoc IFCMVault
    uint64 public emergencyRecoveryValidAt;
    /// @inheritdoc IFCMVault
    bool public emergencyRecoveryActive;
    /// @inheritdoc IFCMVault
    bool public emergencyRecovered;

    // - Admin-controlled parameters & fees ------------------
    /// @inheritdoc IFCMVault
    uint256 public maxTvl;
    /// @inheritdoc IFCMVault
    uint256 public maxSlippageBps;
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
    /// @inheritdoc IFCMVault
    mapping(address => bool) public earlyAccess;

    /// @dev Reverts if the vault is in emergency recovery mode.
    modifier notInRecovery() {
        _notInRecovery();
        _;
    }

    /// @dev Reverts if the vault executed emergency recovery.
    modifier notRecovered() {
        _notRecovered();
        _;
    }

    /// @dev Emits a `VaultState` snapshot after the wrapped function body runs. Placed after `_;` so the event reflects
    /// post-call state. Modifying entry points accrue market interest before mutating, so the debt read here is fresh.
    modifier logsVaultState() {
        _;
        _logVaultState();
    }

    constructor(InitParams memory p) ERC20(p.name, p.symbol) Ownable(p.owner) {
        require(p.healthFactorMin >= MorphoLib.WAD, BelowMinWad(p.healthFactorMin));
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
        require(p.yieldFactorMax >= MorphoLib.WAD, BelowMinWad(p.yieldFactorMax));
        require(p.yieldLoanPool != address(0), ZeroAddress());
        require(p.collateralLoanPool != address(0), ZeroAddress());

        COLLATERAL_TOKEN = p.collateralToken;
        LOAN_TOKEN = p.loanToken;
        YIELD_TOKEN = p.yieldToken;

        HEALTH_FACTOR_MIN = p.healthFactorMin;
        HEALTH_FACTOR_MIN_TARGET = p.healthFactorMinTarget;
        HEALTH_FACTOR_MAX = p.healthFactorMax;
        HEALTH_FACTOR_MAX_TARGET = p.healthFactorMaxTarget;
        YIELD_FACTOR_MAX = p.yieldFactorMax;

        COLLATERAL_LOAN_POOL = p.collateralLoanPool;
        COLLATERAL_LOAN_POOL_FEE = p.collateralLoanPoolFee;
        YIELD_LOAN_POOL = p.yieldLoanPool;
        YIELD_LOAN_POOL_FEE = p.yieldLoanPoolFee;

        MARKET_ORACLE = p.marketOracle;
        MARKET_IRM = p.marketIrm;
        MARKET_LLTV = p.marketLltv;
        YIELD_ORACLE = p.yieldOracle;
        MORPHO = p.morpho;
        SWAP_ROUTER = p.swapRouter;

        uint256 maxAllowance = type(uint256).max;
        p.collateralToken.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(SWAP_ROUTER), maxAllowance);
        p.yieldToken.forceApprove(address(SWAP_ROUTER), maxAllowance);
        // redeem's Case-B flash sells collateral for the debt shortfall.
        p.collateralToken.forceApprove(address(SWAP_ROUTER), maxAllowance);

        lastFeeAccrual = block.timestamp;
        // Seed the HWM at the starting price-per-share so the first deposit isn't counted as performance.
        perfHighWaterMark = MorphoLib.WAD / (10 ** DECIMALS_OFFSET);
    }

    /// @inheritdoc IFCMVault
    function setMaxSlippageBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_SLIPPAGE_BPS, InvalidSlippage());
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setManagementFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_MANAGEMENT_FEE_BPS, InvalidFee());
        _accrueFees();
        emit ManagementFeeSet(managementFeeBps, newBps);
        managementFeeBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setPerformanceFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_PERFORMANCE_FEE_BPS, InvalidFee());
        _accrueFees();
        emit PerformanceFeeSet(performanceFeeBps, newBps);
        performanceFeeBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setFeeRecipient(address newRecipient) external onlyOwner {
        _accrueFees();
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @inheritdoc IFCMVault
    function grantEarlyAccess(address account) external onlyOwner {
        earlyAccess[account] = true;
        emit EarlyAccessGranted(account);
    }

    /// @inheritdoc IFCMVault
    function revokeEarlyAccess(address account) external onlyOwner {
        earlyAccess[account] = false;
        emit EarlyAccessRevoked(account);
    }

    /// @inheritdoc IFCMVault
    function accrueFees() external nonReentrant {
        _accrueFees();
    }

    /// @inheritdoc IFCMVault
    function rebalance() external nonReentrant logsVaultState notRecovered {
        _accrueFees();
        _adjustLeverage();
    }

    /// @inheritdoc IFCMVault
    function harvest(uint256 maximumYield) external nonReentrant notInRecovery logsVaultState {
        _accrueFees();
        _harvest(maximumYield);
    }

    /// @inheritdoc IFCMVault
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @inheritdoc IFCMVault
    function scheduleEmergencyRecovery() external onlyOwner {
        emergencyRecoveryValidAt = SafeCast.toUint64(block.timestamp + EMERGENCY_RECOVERY_DELAY);
        emergencyRecoveryActive = true;
        emit EmergencyRecoveryScheduled(emergencyRecoveryValidAt);
    }

    /// @inheritdoc IFCMVault
    function cancelEmergencyRecovery() external onlyOwner {
        require(!emergencyRecovered, EmergencyRecoveryActive());
        emergencyRecoveryValidAt = 0;
        emergencyRecoveryActive = false;
        emit EmergencyRecoveryCancelled();
    }

    /// @inheritdoc IFCMVault
    function executeEmergencyRecovery() external onlyOwner {
        require(emergencyRecoveryValidAt != 0, EmergencyRecoveryNotReady());
        // forge-lint: disable-next-line(block-timestamp), manipulation doesn't matter the delay is multiple days
        require(block.timestamp >= emergencyRecoveryValidAt, EmergencyRecoveryNotReady());
        emergencyRecovered = true;

        uint256 marketCollateral = MORPHO.collateral(_market());
        if (marketCollateral > 0) MORPHO.withdrawCollateral(_market(), marketCollateral);

        address to = owner();
        uint256 collateralOut = COLLATERAL_TOKEN.balanceOf(address(this));
        uint256 yieldOut = YIELD_TOKEN.balanceOf(address(this));
        uint256 loanOut = LOAN_TOKEN.balanceOf(address(this));
        COLLATERAL_TOKEN.safeTransfer(to, collateralOut);
        YIELD_TOKEN.safeTransfer(to, yieldOut);
        LOAN_TOKEN.safeTransfer(to, loanOut);

        emit EmergencyRecoveryExecuted(collateralOut, yieldOut, loanOut);
    }

    /// @inheritdoc IFCMVault
    function deposit(uint256 assets, address receiver)
        external
        override
        nonReentrant
        notInRecovery
        logsVaultState
        returns (uint256 shares)
    {
        if (assets == 0) return 0;
        // Accrue fees first so the deposit prices in at the post-fee share price.
        _accrueFees();

        uint256 navBefore = totalAssets();
        // Don't mint against a zero NAV while shares exist: the `navBefore + 1` denominator
        // below would collapse and mint a disproportionate amount. Empty-vault first deposits
        // (totalSupply() == 0) are unaffected.
        // slither-disable-next-line incorrect-equality -> exact-zero is the intended guard (totalAssets clamps to 0)
        if (navBefore == 0 && totalSupply() > 0) revert VaultUnderwater();
        uint256 maxAssets = maxTvl > navBefore ? maxTvl - navBefore : 0;
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), assets);
        MORPHO.supplyCollateral(_market(), assets, address(this), "");

        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            MORPHO.borrow(_market(), toBorrow, 0, address(this), address(this));
            SwapLib.swapExactIn(SWAP_ROUTER, address(LOAN_TOKEN), address(YIELD_TOKEN), YIELD_LOAN_POOL_FEE, toBorrow);
        }

        // the depositor's contribution to NAV, denominated in outer vault assets
        uint256 contributed = totalAssets() - navBefore;
        // mint shares in proportion to the depositor's contribution
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1, Math.Rounding.Floor);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IFCMVault
    function redeem(uint256 shares, address receiver, address owner)
        external
        override
        nonReentrant
        notRecovered
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
        require(MORPHO.healthFactor(_market()) >= HEALTH_FACTOR_MIN, VaultUnhealthy());
        uint256 assetBefore = COLLATERAL_TOKEN.balanceOf(address(this));

        _unwindSlice(shares);
        _burn(owner, shares);

        assets = COLLATERAL_TOKEN.balanceOf(address(this)) - assetBefore;
        COLLATERAL_TOKEN.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @inheritdoc IFCMVault
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        notRecovered
        logsVaultState
        returns (uint256 collateralOut, uint256 yieldOut)
    {
        if (shares == 0) return (0, 0);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        // Accrue fees first so the redeemer bears their share of accrued fees.
        _accrueFees();
        uint256 claims = _totalClaims();

        // Caller repays the pro-rata debt slice (rounded up - never under-repays);
        // the caller supplies the LOAN_TOKEN, so no swap is needed.
        uint256 debt = MORPHO.debt(_market());
        uint256 debtToRepay = debt.mulDiv(shares, claims, Math.Rounding.Ceil);
        if (debtToRepay > 0) {
            LOAN_TOKEN.safeTransferFrom(msg.sender, address(this), debtToRepay);
            // slither-disable-next-line unused-return -> repay amount is known (debtToRepay); Morpho reverts on failure
            MORPHO.repay(_market(), debtToRepay, 0, address(this), "");
        }

        // Pro-rata collateral + yield, delivered in kind (rounded down).
        collateralOut = MORPHO.collateral(_market()).mulDiv(shares, claims, Math.Rounding.Floor);
        yieldOut = YIELD_TOKEN.balanceOf(address(this)).mulDiv(shares, claims, Math.Rounding.Floor);

        _burn(owner, shares);

        if (collateralOut > 0) {
            MORPHO.withdrawCollateral(_market(), collateralOut);
            COLLATERAL_TOKEN.safeTransfer(receiver, collateralOut);
        }
        if (yieldOut > 0) YIELD_TOKEN.safeTransfer(receiver, yieldOut);

        emit RedeemInKind({
            caller: msg.sender,
            receiver: receiver,
            owner: owner,
            shares: shares,
            debtRepaid: debtToRepay,
            collateralOut: collateralOut,
            yieldOut: yieldOut
        });
    }

    // solhint-enable ordering

    /// @inheritdoc IFCMVault
    function asset() external view returns (address) {
        return address(COLLATERAL_TOKEN);
    }

    /// @inheritdoc IFCMVault
    function convertToShares(uint256 assets) external view returns (uint256 shares) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IFCMVault
    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// @inheritdoc IFCMVault
    function maxDeposit(address receiver) external view returns (uint256) {
        if (emergencyRecoveryActive) return 0;
        if (!earlyAccess[receiver]) return 0;
        uint256 cachedTotalAssets = totalAssets();
        // Mirror the deposit() underwater guard: 0 when marked underwater with holders.
        // slither-disable-next-line incorrect-equality -> exact-zero is the intended guard (totalAssets clamps to 0)
        if (cachedTotalAssets == 0 && totalSupply() > 0) return 0;
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @inheritdoc IFCMVault
    function maxRedeem(address owner) external view returns (uint256) {
        if (MORPHO.healthFactor(_market()) < HEALTH_FACTOR_MIN) return 0;
        return balanceOf(owner);
    }

    /// @inheritdoc IFCMVault
    function previewDeposit(uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IFCMVault
    function previewMint(uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function mint(uint256, address) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IFCMVault
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function previewRedeem(uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IFCMVault
    function totalAssets() public view returns (uint256) {
        uint256 collateral = MORPHO.collateral(_market());
        uint256 yieldInCollateral = _yieldToCollateral(YIELD_TOKEN.balanceOf(address(this)));
        uint256 debtInCollateral = _market().debtToCollateral(MORPHO.debt(_market()));
        uint256 gross = collateral + yieldInCollateral;
        if (gross > debtInCollateral) {
            return gross - debtInCollateral;
        }
        return 0;
    }

    /// @dev Leverage leg of `rebalance`, rebalancing only to the re-entry target just inside the nearest bound rather
    /// than to a central target.
    /// - If `hf in [HEALTH_FACTOR_MIN, HEALTH_FACTOR_MAX]`, the call is a no-op.
    /// - If `hf > HEALTH_FACTOR_MAX`, the position is under-levered: borrow exactly
    /// `addDebt = (maxBorrow / maxTarget) - debt` of the loan token and swap it to the yield token, landing HF at
    /// `HEALTH_FACTOR_MAX_TARGET` (just below the upper bound).
    /// - If `hf < HEALTH_FACTOR_MIN`, the position is over-levered: sell exactly enough yield token to repay
    /// `repayAmount = debt - (maxBorrow / minTarget)` of debt, landing HF at `HEALTH_FACTOR_MIN_TARGET` (just above
    /// the lower bound).
    /// Rebalancing to the re-entry target nearest the breached bound minimizes swap volume per rebalance. Swap cost is
    /// price impact plus pool fees - both are proportional to swap volume. So, the smallest swap that restores health
    /// within the band incurs the lowest average-case cost. By convention, there is a small buffer between the band's
    /// bound and the target.
    /// Partial rebalancing: the rebalance swap carries a `sqrtPriceLimitX96` derived from the oracle price and
    /// `maxSlippageBps` (see `_yieldLoanSwapLimit`). If reaching the re-entry target would push the pool past that
    /// price, the pool fills as much as possible without reverting.
    /// Note the bound is on the pool's *marginal price* relative to the oracle, i.e. on price impact. The pool's fixed
    /// LP fee is a separate, known cost and is not part of this bound.
    function _adjustLeverage() internal {
        uint256 currentDebt = MORPHO.debt(_market());
        uint256 maxBorrow = MORPHO.maxBorrow(_market());
        uint256 hfBefore = MORPHO.healthFactor(_market());

        // slither-disable-next-line incorrect-equality -> exact-zero is the intended "no recovery pending" guard
        if (hfBefore > HEALTH_FACTOR_MAX && !emergencyRecoveryActive) {
            // Lever-up is frozen while an emergency recovery is pending: the position
            // is slated for in-kind wind-down, so re-levering (more debt + AMM cost)
            // would work against it. Delever stays live - it only de-risks - matching
            // `_harvest`'s recovery gate. Cancelling recovery (`recoveryValidAt = 0`)
            // restores lever-up immediately.
            _rebalanceLever(maxBorrow, currentDebt);
        } else if (hfBefore < HEALTH_FACTOR_MIN) {
            _rebalanceDelever(maxBorrow, currentDebt);
        } else {
            // Inside the dead band, or lever-up suppressed during a pending recovery.
            return;
        }

        emit Rebalanced(msg.sender, hfBefore, MORPHO.healthFactor(_market()));
    }

    /// @notice Unwind a slice of the vault's position, anchored on `p = shares / _totalClaims()` and the realized AMM
    /// @dev Unwind a slice of the vault's position,
    /// anchored on `p = shares / _totalClaims()` and the realized AMM
    /// execution price on the yield leg.
    ///
    /// Step 1 - yield leg (always full pro-rata):
    /// Sell exactly `p * yieldToken.balanceOf(vault)` for loanToken on
    /// the yield/debt pool. Let `loanGot` be the loanToken received
    /// from this swap (measured as a balance delta so any preexisting
    /// loanToken dust is not credited to this redeem).
    ///
    /// Step 2 - branch on realized execution vs. pro-rata debt slice
    /// `d* = p * debt`:
    ///
    /// Case A (`loanGot >= d*`, fair or favorable execution):
    /// a. Repay exactly `d*` to Morpho.
    /// b. Withdraw exactly `p * collateral` of the collateral from Morpho.
    /// c. Reconcile the surplus `loanGot - d*` loanToken to the
    /// collateral on the collateral/debt pool. Surplus is real economic
    /// value (yield leg outgrew the debt leg) and accrues to the
    /// redeemer.
    ///
    /// Case B (`loanGot < d*`, yield underperformed at the AMM):
    /// a. Flash-borrow `p * collateral` of the *collateral* from
    /// Morpho and sell just enough of it for the shortfall `d* - loanGot`
    /// in loanToken, so the vault holds the full `d*`.
    /// b. Repay the full `d*`, then withdraw the redeemer's `p * collateral`.
    /// Repaying before withdrawing makes the withdrawal
    /// health-factor-neutral, so it is permitted at any health factor.
    /// c. The flash is repaid in the flashed collateral (the withdrawn slice
    /// covers it); the unsold remainder is the redeemer's full pro-rata
    /// value. No surplus reconcile leg runs in this case.
    ///
    /// The flash borrows the COLLATERAL, not the loan token, on purpose: the
    /// vault is a net borrower of loan token (none sits idle in the Morpho
    /// singleton for us), so flashing loan token would depend on other
    /// suppliers' liquidity and fail at high utilization. Flashing the
    /// redeemer's own `collSlice` - already in the singleton - is
    /// self-collateralized and always available. That self-sufficiency is the
    /// entire reason to use a flash here: a deterministic unwind at any HF with
    /// no dependence on external loan-token liquidity (see `onMorphoFlashLoan`).
    ///
    /// Rounding favors the vault: pro-rata slices are computed with mulDiv
    /// rounding down.
    /// @param shares Vault shares being redeemed (numerator of `p`).
    function _unwindSlice(uint256 shares) internal {
        uint256 claims = _totalClaims();

        // yieldOut is the quantity of yield tokens we are selling to satisfy the redemption
        uint256 yieldOut = YIELD_TOKEN.balanceOf(address(this)).mulDiv(shares, claims, Math.Rounding.Floor);
        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));
        if (yieldOut > 0) {
            SwapLib.swapExactIn(SWAP_ROUTER, address(YIELD_TOKEN), address(LOAN_TOKEN), YIELD_LOAN_POOL_FEE, yieldOut);
        }
        uint256 loanGot = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;

        uint256 debtSlice = MORPHO.debt(_market()).mulDiv(shares, claims, Math.Rounding.Ceil);
        uint256 collSlice = MORPHO.collateral(_market()).mulDiv(shares, claims, Math.Rounding.Floor);

        if (loanGot >= debtSlice) {
            // Case A: full pro-rata unwind, reconcile surplus to the collateral.
            // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
            if (debtSlice > 0) MORPHO.repay(_market(), debtSlice);
            if (collSlice > 0) MORPHO.withdrawCollateral(_market(), collSlice);
            uint256 surplus = loanGot - debtSlice;
            if (surplus > 0) {
                SwapLib.swapExactIn(
                    SWAP_ROUTER, address(LOAN_TOKEN), address(COLLATERAL_TOKEN), COLLATERAL_LOAN_POOL_FEE, surplus
                );
            }
        } else {
            // Case B: yield sale fell short. Flash the redeemer's own collateral
            // slice (self-collateralized - rationale in the @dev above), sell enough
            // for the shortfall, and cover the full debt slice in `onMorphoFlashLoan`.
            MORPHO.flashLoan(address(COLLATERAL_TOKEN), collSlice, abi.encode(debtSlice, debtSlice - loanGot));
        }
    }

    // solhint-disable ordering, morpho-flash-loan essentially internal

    /// @notice Morpho flash-loan callback for redeem's Case-B path. Only callable
    /// by Morpho, which only invokes it when the vault itself initiated the
    /// flash loan (Morpho calls back the caller of `flashLoan`).
    /// @dev    On entry the vault holds `loanGot` (from the yield sale) plus the
    /// flash-borrowed collateral (`collSlice`, the first arg). Sell just
    /// enough of it for the `shortfall` loan token so the vault holds the
    /// full `debtSlice`, repay the slice, then withdraw the redeemer's
    /// `collSlice` (hf-neutral, permitted at any HF). Morpho reclaims the
    /// flashed `collSlice`; the withdrawn slice covers it and the unsold
    /// remainder is delivered to the redeemer by `redeem`. Reverts if the
    /// redeemer's own collateral slice cannot cover the shortfall (underwater).
    /// @param collSlice The amount of collateral to flash-borrow.
    /// @param data ABI-encoded `(debtSlice, shortfall)` from `_unwindSlice`.
    function onMorphoFlashLoan(uint256 collSlice, bytes calldata data) external {
        require(msg.sender == address(MORPHO), Unauthorized());
        (uint256 debtSlice, uint256 shortfall) = abi.decode(data, (uint256, uint256));

        // Sell just enough of the flashed collateral for exactly `shortfall` loan
        // token, spending at most the slice; with `loanGot` already held that makes
        // the full `debtSlice`.
        SwapLib.swapExactOut(
            SWAP_ROUTER, address(COLLATERAL_TOKEN), address(LOAN_TOKEN), COLLATERAL_LOAN_POOL_FEE, shortfall, collSlice
        );
        // Repay the slice, THEN withdraw the redeemer's collateral (hf-neutral). Morpho
        // reclaims the flashed `collSlice`; the withdrawn slice covers it, unsold rest stays.
        // slither-disable-next-line unused-return -> repay amount is known (debtSlice); Morpho reverts on failure
        MORPHO.repay(_market(), debtSlice);
        MORPHO.withdrawCollateral(_market(), collSlice);
    }

    // solhint-enable ordering

    /// @notice Lever-up branch of `rebalance`: position is under-levered (`hf > HEALTH_FACTOR_MAX`). Borrow exactly the
    /// debt slice that lands the position at `HEALTH_FACTOR_MAX_TARGET` and swap it into yield token.
    /// @dev `targetDebt = maxBorrow * WAD / HEALTH_FACTOR_MAX_TARGET` is the debt level that, against the current
    /// collateral, produces an HF of exactly `HEALTH_FACTOR_MAX_TARGET` (just below the upper bound).
    /// Since `hf > max >= maxTarget`, `currentDebt < targetDebt`. The borrow leg adds `targetDebt - currentDebt`.
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
        uint256 targetDebt = maxBorrow.mulDiv(MorphoLib.WAD, HEALTH_FACTOR_MAX_TARGET, Math.Rounding.Floor);
        if (targetDebt <= currentDebt) return 0;
        uint256 borrowAmount = targetDebt - currentDebt;

        (uint160 yieldLoanPriceLimit, bool ok) = _yieldLoanSwapLimit(address(LOAN_TOKEN));
        if (!ok) return 0; // pool already past the slippage bound - no-op.

        // Borrow first, then swap loan->yield bounded by the price limit. The
        // pool partial-fills up to the limit; whatever loan it does not consume
        // stays with the vault and is repaid below, so we only lever by the
        // amount actually converted to yield.
        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));
        MORPHO.borrow(_market(), borrowAmount);
        SwapLib.swapExactInToLimit(
            SWAP_ROUTER,
            address(LOAN_TOKEN),
            address(YIELD_TOKEN),
            YIELD_LOAN_POOL_FEE,
            borrowAmount,
            yieldLoanPriceLimit
        );

        // Repay the loan token the swap left behind, so no idle loan lingers.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
        if (leftover > 0) MORPHO.repay(_market(), leftover);
        additionalDebt = borrowAmount - leftover;
    }

    /// @notice Delever branch of `rebalance`: position is over-levered (`hf < HEALTH_FACTOR_MIN`). Sell yield token for
    /// loan token to repay enough debt to land the position back at `HEALTH_FACTOR_MIN_TARGET`.
    /// @dev Sizing: targetDebt = maxBorrow * WAD / HEALTH_FACTOR_MIN_TARGET
    ///repayAmount = currentDebt - targetDebt
    /// yieldToSell = repayAmount * 1e36 / yieldOraclePrice
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
    function _rebalanceDelever(uint256 maxBorrow, uint256 currentDebt) internal returns (uint256) {
        uint256 targetDebt = maxBorrow.mulDiv(MorphoLib.WAD, HEALTH_FACTOR_MIN_TARGET, Math.Rounding.Floor);
        // No underflow guard: `_rebalanceDelever` is only reached when `hf < MIN`,
        // i.e. `currentDebt > maxBorrow * WAD / MIN`. Since `MIN < MIN_TARGET`, `maxBorrow / MIN >
        // maxBorrow / MIN_TARGET >= targetDebt`, so `currentDebt > targetDebt` always holds here.
        uint256 repayAmount = currentDebt - targetDebt;

        uint256 yieldPrice = IOracle(YIELD_ORACLE).price();
        // Oracle-implied yield amount whose loan-token value is at least
        // `repayAmount` (rounded up; not accounting for slippage)
        uint256 yieldToSell = repayAmount.mulDiv(MorphoLib.ORACLE_PRICE_SCALE, yieldPrice, Math.Rounding.Ceil);

        uint256 yieldBalance = YIELD_TOKEN.balanceOf(address(this));
        if (yieldToSell > yieldBalance) yieldToSell = yieldBalance;
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing to sell, so skip the swap
        if (yieldToSell == 0) return 0;

        (uint160 limit, bool ok) = _yieldLoanSwapLimit(address(YIELD_TOKEN));
        if (!ok) return 0; // pool already past the slippage bound - no-op.

        // Sell yield->loan bounded by the price limit. The pool partial-fills
        // up to it, so a too-large delever still repays as much as the bound
        // allows.
        uint256 loanGot = SwapLib.swapExactInToLimit(
            SWAP_ROUTER, address(YIELD_TOKEN), address(LOAN_TOKEN), YIELD_LOAN_POOL_FEE, yieldToSell, limit
        );

        // Cap repayment at outstanding debt
        if (loanGot > currentDebt) {
            // This case occurs when the swap pool returns a better price than the oracle, resulting in more loan tokens
            // than needed. We happily accept the favorable outcome, even if that means some loan tokens will get lost
            // as idle loan tokens in the vault (trade-off in docs/architecture.md).
            return MORPHO.repayAll(_market());
        }
        // slither-disable-next-line unused-return -> repay amount is known (repaid); Morpho reverts on failure
        if (loanGot > 0) MORPHO.repay(_market(), loanGot);
        return loanGot;
    }

    /// @dev Realize surplus yield: sell the yield held above what the debt needs and supply the proceeds as
    /// collateral. NAV-neutral apart from swap costs. Add-only (no withdraw, no borrow) - it never increases leverage,
    /// so no flash loan is needed and it cannot push the position toward liquidation. No-op when the yield factor
    /// `rho = yieldValue / debt` is within the band (`rho <= YIELD_FACTOR_MAX` - before enough surplus accrues, or a
    /// yield depeg).
    /// Both legs (yield->loan, then loan->collateral) swap under an oracle-derived `sqrtPriceLimitX96`
    /// (`maxSlippageBps` price-impact bound): each pool partial-fills up to its limit, and a pool already past its
    /// bound makes that leg a no-op rather than a revert.
    /// The two legs treat a partial fill differently. Leg 1's unsold surplus stays as yield and is retried next
    /// harvest; leg 2's is one-way - loan it cannot convert is repaid as debt, so that round the surplus deleverages
    /// the position instead of growing collateral. That is value-preserving (a debt paydown, NAV ~flat); the vault is
    /// left underlevered until the health factor drifts above the band and the lever leg re-levers. Leg 2's throughput
    /// tracks collateral/debt pool depth, which `maxTvl` bounds and which `redeemInKind` sidesteps entirely for exits.
    /// Reverts `LeftoverDebt` when leg 2 leaves more loan token behind than the outstanding debt can absorb: the
    /// excess has nowhere to go, and idle loan token is not counted by `totalAssets`, so stranding it would silently
    /// cut NAV. Retry with a smaller `maximumYield`, or once leg 2's pool is back inside its bound. Reachable mainly
    /// at near-zero debt, where `yieldForDebt` collapses and the whole yield balance counts as surplus.
    function _harvest(uint256 maximumYield) internal {
        uint256 currentDebt = MORPHO.debt(_market());

        uint256 yieldPrice = IOracle(YIELD_ORACLE).price();
        uint256 yieldBalance = YIELD_TOKEN.balanceOf(address(this));

        // Yield needed to back the debt at oracle value; only the excess is harvestable surplus. Round up so the
        // retained yield's oracle value stays >= debt (a floor residue would leave it a hair short), keeping the unwind
        // invariant intact.
        uint256 yieldForDebt = currentDebt.mulDiv(MorphoLib.ORACLE_PRICE_SCALE, yieldPrice, Math.Rounding.Ceil);
        // Fire only when the yield factor is above the band's upper edge: yieldBalance > yieldForDebt *
        // YIELD_FACTOR_MAX / WAD (equivalently rho > YIELD_FACTOR_MAX). Then realize back down to yieldForDebt (rho =
        // 1, bare backing).
        if (yieldBalance <= yieldForDebt.mulDiv(YIELD_FACTOR_MAX, MorphoLib.WAD, Math.Rounding.Floor)) return;
        uint256 yieldToHarvest = yieldBalance - yieldForDebt;
        yieldToHarvest = Math.min(yieldToHarvest, maximumYield);

        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));

        // Leg 1: sell surplus yield -> loan on the yield/debt pool, bounded by an oracle-derived price limit
        // (`maxSlippageBps` of price impact). The pool partial-fills up to the limit; when it is already past the bound
        // the swap is skipped and the harvest no-ops. Same mechanism as `_rebalanceDelever`.
        (uint160 yieldLoanPriceLimit, bool ok) = _yieldLoanSwapLimit(address(YIELD_TOKEN));
        if (!ok) return;
        uint256 loanGot = SwapLib.swapExactInToLimit(
            SWAP_ROUTER,
            address(YIELD_TOKEN),
            address(LOAN_TOKEN),
            YIELD_LOAN_POOL_FEE,
            yieldToHarvest,
            yieldLoanPriceLimit
        );
        // A dust surplus (or a pool already at the bound) rounds the swap output to zero; no-op rather than pass a zero
        // amount to the next leg, which the router and Morpho reject.
        // slither-disable-next-line incorrect-equality -> exact-zero guard: nothing realized, skip
        if (loanGot == 0) return;

        // Leg 2: loan -> collateral on the collateral/debt pool, bounded to the market oracle like leg 1 -
        // partial-fills up to the limit, skipped when already past the bound.
        (uint160 collateralLoanPriceLimit, bool collateralOk) = _collateralLoanSwapLimit();
        uint256 collateralAdded = collateralOk
            ? SwapLib.swapExactInToLimit(
                SWAP_ROUTER,
                address(LOAN_TOKEN),
                address(COLLATERAL_TOKEN),
                COLLATERAL_LOAN_POOL_FEE,
                loanGot,
                collateralLoanPriceLimit
            )
            : 0;
        // Supply as collateral only - no re-lever. This raises hf; `rebalance`'s lever branch redeploys the collateral
        // if/when hf later drifts above the band.
        if (collateralAdded > 0) MORPHO.supplyCollateral(_market(), collateralAdded, address(this), "");

        // Repay whatever leg 2 did not convert (a partial fill, or all of it when skipped). More than the outstanding
        // debt cannot be repaid and would sit idle - uncounted by `totalAssets` - so refuse the harvest instead.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        if (leftover > currentDebt) {
            revert LeftoverDebt();
        }
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
        if (leftover > 0) MORPHO.repay(_market(), leftover);

        emit Harvested(yieldToHarvest, collateralAdded);
    }

    /// @dev The health factor `deposit` levers fresh collateral toward: the midpoint of the rebalance band. `rebalance`
    /// only acts at the band's edges, so deposits aim for the center to leave symmetric headroom in both directions
    /// before the position drifts to a bound and triggers a rebalance.
    function _depositTargetHf() internal view returns (uint256) {
        return (HEALTH_FACTOR_MIN + HEALTH_FACTOR_MAX) / 2;
    }

    /// @dev How much loan token to borrow against `newCollaterals` while keeping the position at the deposit-target HF
    /// (`_depositTargetHf`, the band midpoint). Returns the smaller of two caps:
    /// - `capFromNewCollateral`: the borrow `newCollaterals` of fresh collateral could support on its own at the target
    /// HF. - `capFromTargetDebt`: the additional borrow that, combined with existing debt and existing collateral,
    /// would
    /// land the whole position at the target HF.
    ///
    /// Taking the min means each deposit borrows at most its own proportional share of headroom: small deposits cannot
    /// rebalance an over-collateralized protocol back to target, and no deposit can push an already-too-leveraged
    /// position past the target HF (`capFromTargetDebt` clamps to 0 in that case).
    /// Protocol-wide rebalancing (driving the whole position back inside the band regardless of new collateral size) is
    /// the job of `rebalance`, not `deposit`.
    function _targetBorrowAgainst(uint256 newCollaterals) internal view returns (uint256) {
        uint256 targetHf = _depositTargetHf();
        uint256 capFromNewCollateral =
            _market().maxBorrowFor(newCollaterals).mulDiv(MorphoLib.WAD, targetHf, Math.Rounding.Floor);
        uint256 capFromTargetDebt = MORPHO.maxBorrowAtHealthFactor(_market(), targetHf);
        return capFromNewCollateral < capFromTargetDebt ? capFromNewCollateral : capFromTargetDebt;
    }

    /// @dev Routes yield -> debt -> collateral. The two 1e36 oracle scales cancel.
    function _yieldToCollateral(uint256 yieldAmount) internal view returns (uint256) {
        // slither-disable-next-line incorrect-equality -> exact-zero guard: zero yield converts to zero collateral
        if (yieldAmount == 0) return 0;
        return yieldAmount.mulDiv(IOracle(YIELD_ORACLE).price(), _market().oraclePrice(), Math.Rounding.Floor);
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn).
    /// - Mint (`from == 0`): the receiver must be allowlisted.
    /// - Transfer (both non-zero): both sender and receiver must be allowlisted.
    /// - Burn (`to == 0`): always allowed, preserving the exit path for de-allowlisted holders.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (!earlyAccess[to]) {
                revert NoEarlyAccess(to);
            }
            if (from != address(0) && !earlyAccess[from]) {
                revert NoEarlyAccess(from);
            }
        }
        super._update(from, to, value);
    }

    /// @dev Price limit for a swap on the yield/debt pool (rebalance lever/delever and harvest leg 1). The yield oracle
    /// quotes loan per yield token, 1e36-scaled.
    function _yieldLoanSwapLimit(address tokenIn) internal view returns (uint160, bool) {
        uint256 loanPerYield = IOracle(YIELD_ORACLE).price();
        return tokenIn == address(YIELD_TOKEN)
            ? SwapLib.swapLimit(
                YIELD_LOAN_POOL,
                tokenIn,
                address(LOAN_TOKEN),
                loanPerYield,
                MorphoLib.ORACLE_PRICE_SCALE,
                maxSlippageBps
            )
            : SwapLib.swapLimit(
                YIELD_LOAN_POOL,
                tokenIn,
                address(YIELD_TOKEN),
                MorphoLib.ORACLE_PRICE_SCALE,
                loanPerYield,
                maxSlippageBps
            );
    }

    /// @dev Price limit for harvest leg 2's loan->collateral swap on the collateral/debt pool. The market oracle quotes
    /// loan per collateral, 1e36-scaled.
    function _collateralLoanSwapLimit() internal view returns (uint160, bool) {
        return SwapLib.swapLimit(
            COLLATERAL_LOAN_POOL,
            address(LOAN_TOKEN),
            address(COLLATERAL_TOKEN),
            MorphoLib.ORACLE_PRICE_SCALE,
            _market().oraclePrice(),
            maxSlippageBps
        );
    }

    /// @dev Accrue management + performance fees and mint the corresponding shares to `feeRecipient` (dilution - no
    /// assets leave the vault). Always accrues market interest first so NAV is fresh. Skips
    /// minting (never reverts) when the recipient is unset or not allowlisted, so core flows can't be bricked.
    function _accrueFees() internal {
        MorphoLib.accrueInterest(MORPHO, _market());
        uint256 nav = totalAssets();
        uint256 claims = _totalClaims();
        uint256 pricePerShare = nav.mulDiv(MorphoLib.WAD, claims, Math.Rounding.Floor);

        address recipient = feeRecipient;
        if (recipient != address(0) && earlyAccess[recipient] && nav > 0) {
            (uint256 managementFee, uint256 performanceFee, uint256 feeShares) = FeesLib.feesToMint({
                nav: nav,
                claims: claims,
                // pricePerShare: pricePerShare,
                managementFeeBps: managementFeeBps,
                performanceFeeBps: performanceFeeBps,
                perfHighWaterMark: perfHighWaterMark,
                lastFeeAccrual: lastFeeAccrual
            });
            if (feeShares > 0) {
                emit IFCMVault.FeesAccrued(managementFee, performanceFee, feeShares);
                _mint(recipient, feeShares);
            }
        }

        // Advance clock + HWM unconditionally (even when the mint was skipped) so fees meter from when they're enabled,
        // not retroactively - the fee setters accrue first, pinning these to now. Gating them on the mint would
        // back-charge holders from deploy.
        lastFeeAccrual = block.timestamp;
        if (pricePerShare > perfHighWaterMark) perfHighWaterMark = pricePerShare;
    }

    /// @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more
    /// expensive. See
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function _logVaultState() internal {
        emit VaultState(
            MORPHO.collateral(_market()),
            MORPHO.debt(_market()),
            YIELD_TOKEN.balanceOf(address(this)),
            _market().oraclePrice(),
            MorphoLib.ORACLE_PRICE_SCALE,
            IOracle(YIELD_ORACLE).price()
        );
    }

    function _market() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(LOAN_TOKEN),
            collateralToken: address(COLLATERAL_TOKEN),
            oracle: MARKET_ORACLE,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
    }

    function _notInRecovery() internal view {
        require(!emergencyRecoveryActive, EmergencyRecoveryActive());
    }

    function _notRecovered() internal view {
        require(!emergencyRecovered, EmergencyRecoveryActive());
    }
}
