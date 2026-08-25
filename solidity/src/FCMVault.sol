// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "./interfaces/IFCMVault.sol";
import {ISwapRouter02} from "./interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "./interfaces/external/IUniswapV3Pool.sol";
import "./libraries/ConstantsLib.sol";
import {FeesLib} from "./libraries/FeesLib.sol";
import {MorphoLib} from "./libraries/MorphoLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoRepayCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParams, MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
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
contract FCMVault is IFCMVault, ERC20, Ownable2Step, ReentrancyGuard, IMorphoRepayCallback {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    /// @dev Hard cap on the management fee (10%/yr) - owner cannot exceed.
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 1000;
    /// @dev Hard cap on the performance fee (50%) - owner cannot exceed.
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 5000;
    /// @dev Hard cap on the maxSlippageBps (10%) - owner cannot exceed.
    uint16 internal constant MAX_SLIPPAGE_BPS = 1000;
    /// @inheritdoc IFCMVault
    uint32 public constant EMERGENCY_RECOVERY_DELAY = 7 days;

    /// @inheritdoc IFCMVault
    IERC20 public immutable COLLATERAL_TOKEN;
    /// @inheritdoc IFCMVault
    IERC20 public immutable LOAN_TOKEN;
    /// @inheritdoc IFCMVault
    IERC20 public immutable YIELD_TOKEN;

    /// @inheritdoc IFCMVault
    uint128 public immutable LTV_MIN;
    /// @inheritdoc IFCMVault
    uint128 public immutable LTV_MIN_TARGET;
    /// @inheritdoc IFCMVault
    uint128 public immutable LTV_MAX;
    /// @inheritdoc IFCMVault
    uint128 public immutable LTV_MAX_TARGET;
    /// @inheritdoc IFCMVault
    uint128 public immutable YIELD_TO_LOAN_MAX;

    /// @inheritdoc IFCMVault
    ISwapRouter02 public immutable SWAP_ROUTER;
    /// @inheritdoc IFCMVault
    IUniswapV3Pool public immutable COLLATERAL_LOAN_POOL;
    /// @inheritdoc IFCMVault
    uint24 public immutable COLLATERAL_LOAN_POOL_FEE;
    /// @inheritdoc IFCMVault
    IUniswapV3Pool public immutable YIELD_LOAN_POOL;
    /// @inheritdoc IFCMVault
    uint24 public immutable YIELD_LOAN_POOL_FEE;

    /// @inheritdoc IFCMVault
    IMorpho public immutable MORPHO;
    /// @inheritdoc IFCMVault
    IOracle public immutable COLLATERAL_ORACLE;
    /// @inheritdoc IFCMVault
    address public immutable MARKET_IRM;
    /// @inheritdoc IFCMVault
    uint256 public immutable MARKET_LLTV;
    /// @inheritdoc IFCMVault
    IOracle public immutable YIELD_ORACLE;

    /// @inheritdoc IFCMVault
    uint256 public maxTvl;

    /// @inheritdoc IFCMVault
    uint64 public emergencyRecoveryValidAt;
    /// @inheritdoc IFCMVault
    uint16 public maxSlippageBps;
    /// @inheritdoc IFCMVault
    uint16 public managementFeeBps;
    /// @inheritdoc IFCMVault
    uint16 public performanceFeeBps;
    /// @inheritdoc IFCMVault
    uint64 public lastFeeAccrual;
    /// @inheritdoc IFCMVault
    bool public emergencyRecoveryActive;
    /// @inheritdoc IFCMVault
    bool public emergencyRecovered;

    /// @inheritdoc IFCMVault
    address public feeRecipient;
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
        require(p.ltvMin < p.ltvMinTarget, InvalidLtv());
        require(p.ltvMinTarget < p.ltvMaxTarget, InvalidLtv());
        require(p.ltvMaxTarget < p.ltvMax, InvalidLtv());
        require(p.ltvMax < p.marketLltv, InvalidLtv());

        require(p.yieldToLoanMax >= LTV_SCALE, InvalidYieldFactor());

        require(p.yieldLoanPool != address(0), ZeroAddress());
        require(p.collateralLoanPool != address(0), ZeroAddress());

        COLLATERAL_TOKEN = IERC20(p.collateralToken);
        LOAN_TOKEN = IERC20(p.loanToken);
        YIELD_TOKEN = IERC20(p.yieldToken);

        LTV_MIN = p.ltvMin;
        LTV_MIN_TARGET = p.ltvMinTarget;
        LTV_MAX = p.ltvMax;
        LTV_MAX_TARGET = p.ltvMaxTarget;
        YIELD_TO_LOAN_MAX = p.yieldToLoanMax;

        COLLATERAL_LOAN_POOL = IUniswapV3Pool(p.collateralLoanPool);
        COLLATERAL_LOAN_POOL_FEE = IUniswapV3Pool(p.collateralLoanPool).fee();
        YIELD_LOAN_POOL = IUniswapV3Pool(p.yieldLoanPool);
        YIELD_LOAN_POOL_FEE = IUniswapV3Pool(p.yieldLoanPool).fee();

        COLLATERAL_ORACLE = IOracle(p.collateralOracle);
        MARKET_IRM = p.marketIrm;
        MARKET_LLTV = p.marketLltv;
        YIELD_ORACLE = IOracle(p.yieldOracle);
        MORPHO = IMorpho(p.morpho);
        SWAP_ROUTER = ISwapRouter02(p.swapRouter);

        uint256 maxAllowance = type(uint256).max;
        COLLATERAL_TOKEN.forceApprove(address(MORPHO), maxAllowance);
        LOAN_TOKEN.forceApprove(address(MORPHO), maxAllowance);
        COLLATERAL_TOKEN.forceApprove(address(SWAP_ROUTER), maxAllowance);
        LOAN_TOKEN.forceApprove(address(SWAP_ROUTER), maxAllowance);
        YIELD_TOKEN.forceApprove(address(SWAP_ROUTER), maxAllowance);

        // Seed the HWM at the starting price-per-share so the first deposit isn't counted as performance.
        perfHighWaterMark = LTV_SCALE / (10 ** _decimalsOffset());
    }

    /// @inheritdoc IFCMVault
    function setMaxSlippageBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_SLIPPAGE_BPS, InvalidSlippage());
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setManagementFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_MANAGEMENT_FEE_BPS, InvalidFee());
        _accrueFees();
        emit ManagementFeeSet(managementFeeBps, newBps);
        managementFeeBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setPerformanceFeeBps(uint16 newBps) external onlyOwner {
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
        uint256 ltv = _ltv();
        if (ltv < LTV_MIN && !emergencyRecoveryActive) {
            _rebalanceLever();
        } else if (ltv > LTV_MAX) {
            _rebalanceDelever();
        } else {
            return;
        }

        emit Rebalanced(msg.sender, ltv, _ltv());
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

        uint256 marketCollateral = _collateral();
        if (marketCollateral > 0) MORPHO.withdrawCollateral(_market(), marketCollateral, address(this), address(this));

        address to = owner();
        uint256 collateralOut = COLLATERAL_TOKEN.balanceOf(address(this));
        uint256 yieldOut = _yield();
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
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _accrueFees();
        require(_isHealthy(), VaultUnhealthy());
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

        _accrueFees();
        uint256 totalSupply = totalSupply();
        _burn(owner, shares);

        uint256 borrowShares =
            MORPHO.borrowShares(_market(), address(this)).mulDiv(shares, totalSupply, Math.Rounding.Ceil);
        uint256 debtToRepay = 0;
        if (borrowShares > 0) {
            debtToRepay = MorphoLib.borrowSharesToAssets(MORPHO, _market(), borrowShares);
            LOAN_TOKEN.safeTransferFrom(msg.sender, address(this), debtToRepay);
            // slither-disable-next-line unused-return -> repay amount is known (debtToRepay); Morpho reverts on failure
            MORPHO.repay(_market(), 0, borrowShares, address(this), "");
        }

        uint256 collateral = _collateral();
        collateralOut = collateral.mulDiv(shares, totalSupply, Math.Rounding.Floor);
        yieldOut = _yield().mulDiv(shares, totalSupply, Math.Rounding.Floor);

        if (collateralOut > 0) {
            MORPHO.withdrawCollateral(_market(), collateralOut, address(this), address(this));
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
        if (cachedTotalAssets == 0 && totalSupply() > 0) return 0;
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @inheritdoc IFCMVault
    function maxRedeem(address owner) external view returns (uint256) {
        if (emergencyRecovered) return 0;
        if (!_isHealthy()) return 0;
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
        uint256 collateral = _collateral();
        uint256 yieldInCollateral = _yieldToCollateral(_yield());

        uint256 debt = _debt();
        uint256 debtInCollateral = debt.mulDiv(ORACLE_PRICE_SCALE, COLLATERAL_ORACLE.price(), Math.Rounding.Floor);

        uint256 gross = collateral + yieldInCollateral;
        if (gross > debtInCollateral) {
            return gross - debtInCollateral;
        }
        return 0;
    }

    /// @dev Unwind a proportional slice of the vault's position for `redeem`. Sells the pro-rata yield slice for loan
    /// token, then repays the pro-rata debt slice by borrow shares via Morpho's `onMorphoRepay` callback. The callback
    /// withdraws the pro-rata collateral slice and reconciles the realized swap output against the debt. When there is
    /// no debt, the callback is skipped and the collateral is withdrawn directly.
    /// @param shares Vault shares being redeemed.
    function _unwindSlice(uint256 shares) internal {
        uint256 totalSupply = totalSupply();

        uint256 yieldSlice = _yield().mulDiv(shares, totalSupply, Math.Rounding.Floor);
        uint256 loanGot = 0;
        if (yieldSlice > 0) {
            loanGot = SwapLib.swapExactIn(
                SWAP_ROUTER, address(YIELD_TOKEN), address(LOAN_TOKEN), YIELD_LOAN_POOL_FEE, yieldSlice
            );
        }

        uint256 borrowShares = MORPHO.borrowShares(_market(), address(this));
        uint256 borrowShareSlice = borrowShares.mulDiv(shares, totalSupply, Math.Rounding.Ceil);
        uint256 collSlice = _collateral().mulDiv(shares, totalSupply, Math.Rounding.Floor);

        if (borrowShareSlice > 0) {
            MORPHO.repay(_market(), 0, borrowShareSlice, address(this), abi.encode(collSlice, loanGot));
        } else {
            _withdrawAndReconcile(collSlice, loanGot, 0);
        }
    }

    function onMorphoRepay(uint256 debtSlice, bytes calldata data) external {
        require(msg.sender == address(MORPHO), Unauthorized());
        (uint256 collSlice, uint256 loanGot) = abi.decode(data, (uint256, uint256));
        _withdrawAndReconcile(collSlice, loanGot, debtSlice);
    }

    /// @dev Withdraw `collSlice` of collateral and reconcile the realized `loanGot` against `debtSlice`: sell
    /// collateral for any shortfall, or swap surplus loan token back to collateral so the redeemer receives the full
    /// pro-rata value as collateral.
    function _withdrawAndReconcile(uint256 collSlice, uint256 loanGot, uint256 debtSlice) internal {
        if (collSlice > 0) {
            MORPHO.withdrawCollateral(_market(), collSlice, address(this), address(this));
        }
        if (loanGot < debtSlice) {
            SwapLib.swapExactOut(
                SWAP_ROUTER,
                address(COLLATERAL_TOKEN),
                address(LOAN_TOKEN),
                COLLATERAL_LOAN_POOL_FEE,
                debtSlice - loanGot,
                collSlice
            );
        } else if (loanGot > debtSlice) {
            SwapLib.swapExactIn(
                SWAP_ROUTER,
                address(LOAN_TOKEN),
                address(COLLATERAL_TOKEN),
                COLLATERAL_LOAN_POOL_FEE,
                loanGot - debtSlice
            );
        }
    }

    /// @notice Lever-up branch of `rebalance`: position is under-levered (`ltv < LTV_MIN`). Borrow enough to raise the
    /// LTV to `LTV_MIN_TARGET` and swap the borrowed loan token into yield token.
    /// @dev The full `borrowAmount` is borrowed up front, then the loan->yield swap runs under a `sqrtPriceLimitX96`
    /// derived from the oracle and `maxSlippageBps`. If the swap would push the pool past that price, the pool fills
    /// only up to it (a partial fill) and the unspent loan token is immediately repaid, so the position lands partway
    /// to `LTV_MIN_TARGET` with no idle loan token left behind. When the pool is already priced past the bound, the
    /// swap is skipped and the borrow is fully repaid (no-op).
    /// @return additionalDebt Net new debt taken on in this call.
    function _rebalanceLever() internal returns (uint256 additionalDebt) {
        uint256 targetDebt = _maxBorrowFor(_collateral(), COLLATERAL_ORACLE.price(), LTV_MIN_TARGET);
        uint256 currentDebt = _debt();
        if (targetDebt <= currentDebt) return 0;
        uint256 borrowAmount = targetDebt - currentDebt;

        (uint160 yieldLoanPriceLimit, bool ok) = _yieldLoanSwapLimit(LOAN_TOKEN);
        if (!ok) return 0; // pool already past the slippage bound - no-op.

        // Borrow first, then swap loan->yield bounded by the price limit. The
        // pool partial-fills up to the limit; whatever loan it does not consume
        // stays with the vault and is repaid below, so we only lever by the
        // amount actually converted to yield.
        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));
        MORPHO.borrow(_market(), borrowAmount, 0, address(this), address(this));
        SwapLib.swapExactInToLimit(
            SWAP_ROUTER, LOAN_TOKEN, YIELD_TOKEN, YIELD_LOAN_POOL_FEE, borrowAmount, yieldLoanPriceLimit
        );

        // Repay the loan token the swap left behind, so no idle loan lingers.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
        if (leftover > 0) MORPHO.repay(_market(), leftover, 0, address(this), "");
        additionalDebt = borrowAmount - leftover;
    }

    /// @notice Delever branch of `rebalance`: position is over-levered (`ltv > LTV_MAX`). Sell yield token for loan
    /// token to repay enough debt to lower the LTV to `LTV_MAX_TARGET`.
    /// @dev The yield->loan swap runs under a `sqrtPriceLimitX96` derived from the oracle and `maxSlippageBps`. If
    /// selling the full `yieldToSell` would push the pool past that price, the pool fills only up to it and the vault
    /// repays just the realized loan token, so the position lands partway to `LTV_MAX_TARGET` rather than reverting.
    /// When the pool is already priced past the bound the swap is skipped entirely (no-op).
    function _rebalanceDelever() internal {
        uint256 targetDebt = _maxBorrowFor(_collateral(), COLLATERAL_ORACLE.price(), LTV_MAX_TARGET);
        uint256 currentDebt = _debt();
        // No underflow guard: `_rebalanceDelever` is only reached when `ltv > LTV_MAX`, so `currentDebt > targetDebt`
        // always holds here since `LTV_MAX > LTV_MAX_TARGET`.
        uint256 repayAmount = currentDebt - targetDebt;

        uint256 yieldPrice = YIELD_ORACLE.price();
        // Oracle-implied yield amount whose loan-token value is at least
        // `repayAmount` (rounded up; not accounting for slippage)
        uint256 yieldToSell = repayAmount.mulDiv(ORACLE_PRICE_SCALE, yieldPrice, Math.Rounding.Ceil);

        uint256 yieldBalance = _yield();
        if (yieldToSell > yieldBalance) yieldToSell = yieldBalance;
        if (yieldToSell == 0) return;

        (uint160 limit, bool ok) = _yieldLoanSwapLimit(YIELD_TOKEN);
        if (!ok) return;

        // Sell yield->loan bounded by the price limit. The pool partial-fills
        // up to it, so a too-large delever still repays as much as the bound
        // allows.
        uint256 loanGot =
            SwapLib.swapExactInToLimit(SWAP_ROUTER, YIELD_TOKEN, LOAN_TOKEN, YIELD_LOAN_POOL_FEE, yieldToSell, limit);

        if (loanGot > 0) {
            if (loanGot > currentDebt) {
                // This case occurs when the swap pool returns a better price than the oracle, resulting in more loan
                // tokens than needed. We happily accept the favorable outcome, even if that means some loan tokens will
                // get lost
                // as idle loan tokens in the vault (trade-off in docs/architecture.md).
                MORPHO.repayAll(_market(), address(this));
                return;
            }
            MORPHO.repay(_market(), loanGot, 0, address(this), "");
        }
    }

    /// @dev Realize surplus yield: sell the yield held above what the debt needs and supply the proceeds as collateral.
    /// NAV-neutral apart from swap costs. Add-only (no withdraw, no borrow) - it never increases leverage, so it cannot
    /// push the position toward liquidation. No-op when the yield-to-loan ratio `rho = yieldValue / debt` is within
    /// the band (`rho <= YIELD_TO_LOAN_MAX`).
    /// Both legs swap under an oracle-derived `sqrtPriceLimitX96` (`maxSlippageBps` price-impact bound): each pool
    /// partial-fills up to its limit, and a pool already past its bound makes that leg a no-op rather than a revert.
    /// Leg 1's unsold surplus stays as yield and is retried next harvest; leg 2's unspent loan is repaid as debt, so
    /// that round the surplus deleverages instead of growing collateral.
    /// Reverts `LeftoverDebt` when leg 2 leaves more loan token behind than the outstanding debt can absorb.
    function _harvest(uint256 maximumYield) internal {
        uint256 currentDebt = _debt();

        uint256 yieldPrice = YIELD_ORACLE.price();
        uint256 yieldBalance = _yield();

        // Yield needed to back the debt at oracle value; only the excess is harvestable surplus. Round up so the
        // retained yield's oracle value stays >= debt (a floor residue would leave it a hair short), keeping the unwind
        // invariant intact.
        uint256 yieldForDebt = currentDebt.mulDiv(ORACLE_PRICE_SCALE, yieldPrice, Math.Rounding.Ceil);
        // Fire only when the yield-to-loan ratio is above the band's upper edge: yieldBalance > yieldForDebt *
        // YIELD_TO_LOAN_MAX / LTV_SCALE (equivalently rho > YIELD_TO_LOAN_MAX). Then realize back down to yieldForDebt
        // (rho = 1, bare backing).
        if (yieldBalance <= yieldForDebt.mulDiv(YIELD_TO_LOAN_MAX, LTV_SCALE, Math.Rounding.Floor)) return;
        uint256 yieldToHarvest = yieldBalance - yieldForDebt;
        yieldToHarvest = Math.min(yieldToHarvest, maximumYield);
        if (yieldToHarvest == 0) return;

        uint256 loanBefore = LOAN_TOKEN.balanceOf(address(this));

        // Leg 1: sell surplus yield -> loan on the yield/debt pool, bounded by an oracle-derived price limit
        // (`maxSlippageBps` of price impact). The pool partial-fills up to the limit; when it is already past the bound
        // the swap is skipped and the harvest no-ops. Same mechanism as `_rebalanceDelever`.
        (uint160 yieldLoanPriceLimit, bool ok) = _yieldLoanSwapLimit(YIELD_TOKEN);
        if (!ok) return;
        uint256 loanGot = SwapLib.swapExactInToLimit(
            SWAP_ROUTER, YIELD_TOKEN, LOAN_TOKEN, YIELD_LOAN_POOL_FEE, yieldToHarvest, yieldLoanPriceLimit
        );
        // A dust surplus (or a pool already at the bound) rounds the swap output to zero; no-op rather than pass a zero
        // amount to the next leg, which the router and Morpho reject.
        if (loanGot == 0) return;

        // Leg 2: loan -> collateral on the collateral/debt pool, bounded to the market oracle like leg 1 -
        // partial-fills up to the limit, skipped when already past the bound.
        (uint160 collateralLoanPriceLimit, bool collateralOk) = _collateralLoanSwapLimit();
        uint256 collateralAdded = collateralOk
            ? SwapLib.swapExactInToLimit(
                SWAP_ROUTER, LOAN_TOKEN, COLLATERAL_TOKEN, COLLATERAL_LOAN_POOL_FEE, loanGot, collateralLoanPriceLimit
            )
            : 0;
        // Supply as collateral only - no re-lever. This lowers LTV; `rebalance`'s lever branch redeploys the collateral
        // if/when LTV later drifts below the band.
        if (collateralAdded > 0) MORPHO.supplyCollateral(_market(), collateralAdded, address(this), "");

        // Repay whatever leg 2 did not convert (a partial fill, or all of it when skipped). More than the outstanding
        // debt cannot be repaid and would sit idle - uncounted by `totalAssets` - so refuse the harvest instead.
        uint256 leftover = LOAN_TOKEN.balanceOf(address(this)) - loanBefore;
        if (leftover > currentDebt) {
            revert LeftoverDebt();
        }
        // slither-disable-next-line unused-return -> repay amount is known (leftover); Morpho reverts on failure
        if (leftover > 0) MORPHO.repay(_market(), leftover, 0, address(this), "");

        // Leg 1 partial-fills, so report what the pool actually consumed rather than what was offered.
        emit Harvested(yieldBalance - _yield(), collateralAdded);
    }

    /// @dev The LTV `deposit` levers fresh collateral toward: the midpoint of the rebalance band. `rebalance` only
    /// acts at the band's edges, so deposits aim for the center to leave symmetric headroom in both directions.
    function _depositTargetLtv() internal view returns (uint256) {
        return (LTV_MIN + LTV_MAX) / 2;
    }

    /// @dev How much loan token to borrow against `newCollateral` while keeping the position at the deposit-target LTV
    /// (`_depositTargetLtv`, the band midpoint). Returns the smaller of two caps:
    /// - `capFromNewCollateral`: the borrow `newCollateral` of fresh collateral could support on its own at the target
    /// LTV.
    /// - `capFromTargetDebt`: the additional borrow that, combined with existing debt and collateral, would land the
    /// whole position at the target LTV. Clamps to 0 when the position is already at or above the target.
    /// Taking the min means each deposit borrows at most its own proportional share of headroom.
    function _targetBorrowAgainst(uint256 newCollateral) internal view returns (uint256) {
        uint256 targetLtv = _depositTargetLtv();

        uint256 collateralPrice = COLLATERAL_ORACLE.price();
        uint256 debt = _debt();

        uint256 capFromNewCollateral = _maxBorrowFor(newCollateral, collateralPrice, targetLtv);
        uint256 totalDebtAtTarget = _maxBorrowFor(_collateral(), collateralPrice, targetLtv);
        uint256 capFromTargetDebt = totalDebtAtTarget > debt ? totalDebtAtTarget - debt : 0;
        return capFromNewCollateral < capFromTargetDebt ? capFromNewCollateral : capFromTargetDebt;
    }

    /// @dev Routes yield -> debt -> collateral. The two 1e36 oracle scales cancel.
    function _yieldToCollateral(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return yieldAmount.mulDiv(YIELD_ORACLE.price(), COLLATERAL_ORACLE.price(), Math.Rounding.Floor);
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
    function _yieldLoanSwapLimit(IERC20 tokenIn) internal view returns (uint160, bool) {
        uint256 loanPerYield = YIELD_ORACLE.price();
        return address(tokenIn) == address(YIELD_TOKEN)
            ? SwapLib.swapLimit(YIELD_LOAN_POOL, tokenIn, LOAN_TOKEN, loanPerYield, ORACLE_PRICE_SCALE, maxSlippageBps)
            : SwapLib.swapLimit(YIELD_LOAN_POOL, tokenIn, YIELD_TOKEN, ORACLE_PRICE_SCALE, loanPerYield, maxSlippageBps);
    }

    /// @dev Price limit for harvest leg 2's loan->collateral swap on the collateral/debt pool. The market oracle quotes
    /// loan per collateral, 1e36-scaled.
    function _collateralLoanSwapLimit() internal view returns (uint160, bool) {
        return SwapLib.swapLimit(
            COLLATERAL_LOAN_POOL,
            LOAN_TOKEN,
            COLLATERAL_TOKEN,
            ORACLE_PRICE_SCALE,
            COLLATERAL_ORACLE.price(),
            maxSlippageBps
        );
    }

    /// @dev Accrue management + performance fees and mint the corresponding shares to `feeRecipient` (dilution - no
    /// assets leave the vault). Always accrues market interest first so NAV is fresh. Skips
    /// minting (never reverts) when the recipient is unset or not allowlisted, so core flows can't be bricked.
    function _accrueFees() internal {
        MORPHO.accrueInterest(_market());
        uint256 nav = totalAssets();
        uint256 claims = _totalClaims();
        uint256 pricePerShare = nav.mulDiv(LTV_SCALE, claims, Math.Rounding.Floor);

        address recipient = feeRecipient;
        if (recipient != address(0) && earlyAccess[recipient] && nav > 0) {
            (uint256 managementFee, uint256 performanceFee, uint256 feeShares) = FeesLib.feesToMint({
                nav: nav,
                claims: claims,
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
        lastFeeAccrual = uint64(block.timestamp);
        if (pricePerShare > perfHighWaterMark) perfHighWaterMark = pricePerShare;
    }

    function _logVaultState() internal {
        emit VaultState(_collateral(), _debt(), _yield(), COLLATERAL_ORACLE.price(), YIELD_ORACLE.price());
    }

    function _market() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(LOAN_TOKEN),
            collateralToken: address(COLLATERAL_TOKEN),
            oracle: address(COLLATERAL_ORACLE),
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
    }

    function _collateral() internal view returns (uint256) {
        return MORPHO.collateral(_market(), address(this));
    }

    function _debt() internal view returns (uint256) {
        return MORPHO.debt(_market(), address(this));
    }

    function _yield() internal view returns (uint256) {
        return YIELD_TOKEN.balanceOf(address(this));
    }

    /// @dev Returns how much the current debt is worth in collateral assets.
    function _debtInCollateralAssets() internal view returns (uint256) {
        return _debt().mulDiv(ORACLE_PRICE_SCALE, IOracle(COLLATERAL_ORACLE).price());
    }

    function _ltv() internal view returns (uint256) {
        uint256 coll = _collateral();
        if (coll == 0) return _debt() == 0 ? 0 : type(uint256).max;
        return _debtInCollateralAssets().mulDiv(LTV_SCALE, coll);
    }

    function _isHealthy() internal view returns (bool) {
        return _ltv() <= LTV_MAX;
    }

    function _maxBorrowFor(uint256 collateral, uint256 collateralPrice, uint256 target)
        internal
        pure
        returns (uint256)
    {
        uint256 collateralInDebtAsset = collateral.mulDiv(collateralPrice, ORACLE_PRICE_SCALE);
        return collateralInDebtAsset.mulDiv(target, LTV_SCALE);
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function _notInRecovery() internal view {
        require(!emergencyRecoveryActive, EmergencyRecoveryActive());
    }

    function _notRecovered() internal view {
        require(!emergencyRecovered, EmergencyRecoveryActive());
    }

    /// @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more
    /// expensive. See
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure returns (uint8) {
        return 6;
    }
}
