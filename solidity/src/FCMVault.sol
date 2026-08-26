// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "./interfaces/IFCMVault.sol";
import {IUniswapV3Pool} from "./interfaces/external/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "./interfaces/external/IUniswapV3SwapCallback.sol";
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
contract FCMVault is IFCMVault, ERC20, Ownable2Step, ReentrancyGuard, IMorphoRepayCallback, IUniswapV3SwapCallback {
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
    uint128 public immutable LTV_MAX;

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

    // SLOT 7
    /// @inheritdoc IFCMVault
    uint256 public maxTvl;

    // SLOT 8
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
    uint64 public emergencyRecoveryValidAt;

    // SLOT 9
    /// @inheritdoc IFCMVault
    address public feeRecipient;

    // SLOT 10
    /// @inheritdoc IFCMVault
    uint256 public perfHighWaterMark;

    // SLOT 11
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
        require(p.ltvMin < p.ltvMax, InvalidLtv());
        require(p.ltvMax < p.marketLltv, InvalidLtv());

        require(p.collateralToken != address(0), ZeroAddress());
        require(p.loanToken != address(0), ZeroAddress());
        require(p.yieldToken != address(0), ZeroAddress());
        require(p.yieldLoanPool != address(0), ZeroAddress());
        require(p.collateralLoanPool != address(0), ZeroAddress());

        require(p.collateralOracle != address(0), ZeroAddress());
        require(p.marketIrm != address(0), ZeroAddress());
        require(p.marketLltv != 0, ZeroAddress());
        require(p.yieldOracle != address(0), ZeroAddress());
        require(p.morpho != address(0), ZeroAddress());

        COLLATERAL_TOKEN = IERC20(p.collateralToken);
        LOAN_TOKEN = IERC20(p.loanToken);
        YIELD_TOKEN = IERC20(p.yieldToken);

        LTV_MIN = p.ltvMin;
        LTV_MAX = p.ltvMax;

        COLLATERAL_LOAN_POOL = IUniswapV3Pool(p.collateralLoanPool);
        COLLATERAL_LOAN_POOL_FEE = IUniswapV3Pool(p.collateralLoanPool).fee();
        YIELD_LOAN_POOL = IUniswapV3Pool(p.yieldLoanPool);
        YIELD_LOAN_POOL_FEE = IUniswapV3Pool(p.yieldLoanPool).fee();

        COLLATERAL_ORACLE = IOracle(p.collateralOracle);
        MARKET_IRM = p.marketIrm;
        MARKET_LLTV = p.marketLltv;
        YIELD_ORACLE = IOracle(p.yieldOracle);
        MORPHO = IMorpho(p.morpho);

        uint256 maxAllowance = type(uint256).max;
        COLLATERAL_TOKEN.forceApprove(address(MORPHO), maxAllowance);
        LOAN_TOKEN.forceApprove(address(MORPHO), maxAllowance);

        // Seed the HWM at the starting price-per-share so the first deposit isn't counted as performance.
        perfHighWaterMark = LTV_SCALE / (10 ** _decimalsOffset());
    }

    /// @inheritdoc IFCMVault
    function setMaxSlippageBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_SLIPPAGE_BPS, MaxSlippageExceeded());
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setManagementFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_MANAGEMENT_FEE_BPS, MaxFeeRateExceeded());
        _accrueFees();
        emit ManagementFeeSet(managementFeeBps, newBps);
        managementFeeBps = newBps;
    }

    /// @inheritdoc IFCMVault
    function setPerformanceFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_PERFORMANCE_FEE_BPS, MaxFeeRateExceeded());
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

        uint256 debt = _debt();
        uint256 collateralInDebtAsset = _collateralInDebtAsset();

        uint256 maxDebt = collateralInDebtAsset.mulDiv(LTV_MAX, LTV_SCALE);
        if (debt > maxDebt) {
            uint256 debtToRepay = debt - maxDebt;
            (uint256 yieldSold, uint256 loanRepaid) =
                _swapYieldToLoanWithLimit({yieldToSell: 0, loanToGet: debtToRepay});
            if (loanRepaid > 0) {
                MORPHO.repay(_market(), loanRepaid, 0, address(this), "");
            }
            emit RebalancedDown(msg.sender, yieldSold, loanRepaid);
            return;
        }

        uint256 minDebt = collateralInDebtAsset.mulDiv(LTV_MIN, LTV_SCALE);
        if (debt < minDebt && !emergencyRecoveryActive) {
            uint256 debtToBorrow = minDebt - debt;
            MORPHO.borrow(_market(), debtToBorrow, 0, address(this), address(this));
            (uint256 loanBorrowed, uint256 yieldBought) = _swapLoanToYieldWithLimit({loanToSell: debtToBorrow});
            uint256 leftover = debtToBorrow - loanBorrowed;
            if (leftover > 0) {
                MORPHO.repay(_market(), leftover, 0, address(this), "");
            }
            emit RebalancedUp(msg.sender, loanBorrowed, yieldBought);
            return;
        }
    }

    /// @inheritdoc IFCMVault
    function harvest(uint256 maximumYield) external nonReentrant notInRecovery logsVaultState {
        _accrueFees();

        uint256 yield = _yield();
        uint256 yieldToHarvest = Math.saturatingSub(yield, _debtInYieldAsset());
        yieldToHarvest = Math.min(yieldToHarvest, maximumYield);
        if (yieldToHarvest == 0) return;

        (, uint256 loanOut) = _swapYieldToLoanWithLimit({yieldToSell: yieldToHarvest, loanToGet: 0});
        (uint256 loanIn, uint256 collateralOut) = _swapLoanToCollateralWithLimit(loanOut);
        require(loanIn == loanOut, LeftoverLoanTokens());
        if (collateralOut > 0) {
            MORPHO.supplyCollateral(_market(), collateralOut, address(this), "");
        }

        emit Harvested(msg.sender, yield - _yield(), collateralOut);
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
        require(block.timestamp >= emergencyRecoveryValidAt, EmergencyRecoveryNotReady());
        emergencyRecovered = true;

        uint256 marketCollateral = _collateral();
        if (marketCollateral > 0) MORPHO.withdrawCollateral(_market(), marketCollateral, address(this), address(this));

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
        _accrueFees();

        uint256 navBefore = totalAssets();
        if (navBefore == 0 && totalSupply() > 0) revert VaultUnderwater();
        uint256 maxAssets = Math.saturatingSub(maxTvl, navBefore);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(assets, maxAssets);
        }
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), assets);
        MORPHO.supplyCollateral(_market(), assets, address(this), "");

        uint256 toBorrow = _depositBorrow(assets);
        if (toBorrow > 0) {
            MORPHO.borrow(_market(), toBorrow, 0, address(this), address(this));
            SwapLib.swapExactInToLimit(YIELD_LOAN_POOL, LOAN_TOKEN, YIELD_TOKEN, toBorrow, 0);
        }

        uint256 contributed = totalAssets() - navBefore;
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
        if (!_isHealthy() && _yield() != 0) revert VaultUnhealthy();
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
            MORPHO.repay(_market(), 0, borrowShares, address(this), "");
        }

        collateralOut = _collateral().mulDiv(shares, totalSupply, Math.Rounding.Floor);
        yieldOut = _yield().mulDiv(shares, totalSupply, Math.Rounding.Floor);

        if (collateralOut > 0) {
            MORPHO.withdrawCollateral(_market(), collateralOut, address(this), address(this));
            COLLATERAL_TOKEN.safeTransfer(receiver, collateralOut);
        }
        if (yieldOut > 0) YIELD_TOKEN.safeTransfer(receiver, yieldOut);

        emit RedeemInKind({
            sender: msg.sender,
            receiver: receiver,
            owner: owner,
            debtRepaid: debtToRepay,
            collateralOut: collateralOut,
            yieldOut: yieldOut,
            shares: shares
        });
    }

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
        uint256 totalAssets_ = totalAssets();
        if (totalAssets_ == 0 && totalSupply() > 0) return 0;
        return Math.saturatingSub(maxTvl, totalAssets_);
    }

    /// @inheritdoc IFCMVault
    function maxRedeem(address owner) external view returns (uint256) {
        if (emergencyRecovered) return 0;
        if (!_isHealthy() && _yield() != 0) return 0;
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
        uint256 collateralPrice = COLLATERAL_ORACLE.price();
        uint256 yieldInDebtAsset = _yield().mulDiv(YIELD_ORACLE.price(), ORACLE_PRICE_SCALE, Math.Rounding.Floor);
        uint256 yieldInCollateralAsset =
            yieldInDebtAsset.mulDiv(ORACLE_PRICE_SCALE, collateralPrice, Math.Rounding.Floor);
        uint256 debtInCollateralAsset = _debt().mulDiv(ORACLE_PRICE_SCALE, collateralPrice, Math.Rounding.Ceil);

        uint256 gross = _collateral() + yieldInCollateralAsset;
        return Math.saturatingSub(gross, debtInCollateralAsset);
    }

    /// @dev Unwind a proportional slice of the vault's position for `redeem`. Leaves unwound collateral in the vault.
    /// @param shares Vault shares being redeemed.
    function _unwindSlice(uint256 shares) internal {
        uint256 totalSupply = totalSupply();

        uint256 yieldSlice = _yield().mulDiv(shares, totalSupply, Math.Rounding.Floor);
        uint256 loanOut = 0;
        if (yieldSlice > 0) {
            (, loanOut) = SwapLib.swapExactInToLimit(YIELD_LOAN_POOL, YIELD_TOKEN, LOAN_TOKEN, yieldSlice, 0);
        }

        uint256 borrowShares = MORPHO.borrowShares(_market(), address(this));
        uint256 borrowShareSlice = borrowShares.mulDiv(shares, totalSupply, Math.Rounding.Ceil);
        uint256 collSlice = _collateral().mulDiv(shares, totalSupply, Math.Rounding.Floor);

        if (borrowShareSlice == 0) {
            if (collSlice > 0) {
                MORPHO.withdrawCollateral(_market(), collSlice, address(this), address(this));
            }
            if (loanOut > 0) {
                _swapLoanToCollateral(loanOut);
            }
            return;
        }
        MORPHO.repay(_market(), 0, borrowShareSlice, address(this), abi.encode(collSlice, loanOut));
    }

    /// @dev Morpho callback from _unwindSlice.
    function onMorphoRepay(uint256 debtSlice, bytes calldata data) external {
        require(msg.sender == address(MORPHO), Unauthorized());
        (uint256 collSlice, uint256 loanOut) = abi.decode(data, (uint256, uint256));
        if (collSlice > 0) {
            MORPHO.withdrawCollateral(_market(), collSlice, address(this), address(this));
        }
        if (loanOut < debtSlice) {
            SwapLib.swapExactOutToLimit(COLLATERAL_LOAN_POOL, COLLATERAL_TOKEN, LOAN_TOKEN, debtSlice - loanOut, 0);
        } else if (loanOut > debtSlice) {
            _swapLoanToCollateral(loanOut - debtSlice);
        }
    }

    /// @dev Uniswap callback for yield/loan and collateral/loan swaps.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(msg.sender == address(YIELD_LOAN_POOL) || msg.sender == address(COLLATERAL_LOAN_POOL), Unauthorized());
        address tokenIn = abi.decode(data, (address));
        uint256 amountToPay = amount0Delta > 0 ? SafeCast.toUint256(amount0Delta) : SafeCast.toUint256(amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
    }

    function _swapYieldToLoanWithLimit(uint256 yieldToSell, uint256 loanToGet)
        internal
        returns (uint256 yieldIn, uint256 loanOut)
    {
        if (yieldToSell > 0) {
            (uint160 limit, bool ok) = _yieldLoanSwapLimit(YIELD_TOKEN);
            if (!ok) return (0, 0);
            (uint256 consumed, uint256 out) =
                SwapLib.swapExactInToLimit(YIELD_LOAN_POOL, YIELD_TOKEN, LOAN_TOKEN, yieldToSell, limit);
            return (consumed, out);
        } else {
            if (_yield() == 0) return (0, 0);
            (uint160 limit, bool ok) = _yieldLoanSwapLimit(YIELD_TOKEN);
            if (!ok) return (0, 0);
            (uint256 in_, uint256 out_) =
                SwapLib.swapExactOutToLimit(YIELD_LOAN_POOL, YIELD_TOKEN, LOAN_TOKEN, loanToGet, limit);
            return (in_, out_);
        }
    }

    function _swapLoanToYieldWithLimit(uint256 loanToSell) internal returns (uint256 loanIn, uint256 yieldOut) {
        (uint160 limit, bool ok) = _yieldLoanSwapLimit(LOAN_TOKEN);
        if (!ok) return (0, 0);
        (uint256 consumed, uint256 out) =
            SwapLib.swapExactInToLimit(YIELD_LOAN_POOL, LOAN_TOKEN, YIELD_TOKEN, loanToSell, limit);
        return (consumed, out);
    }

    function _swapLoanToCollateral(uint256 loanToSell) internal returns (uint256 loanIn, uint256 collateralOut) {
        return SwapLib.swapExactInToLimit(COLLATERAL_LOAN_POOL, LOAN_TOKEN, COLLATERAL_TOKEN, loanToSell, 0);
    }

    function _swapLoanToCollateralWithLimit(uint256 loanToSell)
        internal
        returns (uint256 loanIn, uint256 collateralOut)
    {
        (uint160 limit, bool ok) = _collateralLoanSwapLimit();
        if (!ok) return (0, 0);
        (uint256 consumed, uint256 out) =
            SwapLib.swapExactInToLimit(COLLATERAL_LOAN_POOL, LOAN_TOKEN, COLLATERAL_TOKEN, loanToSell, limit);
        return (consumed, out);
    }

    /// @dev The LTV `deposit` levers fresh collateral toward: the midpoint of the rebalance band.
    function _depositTargetLtv() internal view returns (uint256) {
        return (LTV_MIN + LTV_MAX) / 2;
    }

    /// @dev Loan to borrow on a `newCollateral` deposit so the whole position lands at the deposit-target LTV.
    /// Capped by what the fresh collateral can support alone and by the existing position's headroom to that target.
    function _depositBorrow(uint256 newCollateral) internal view returns (uint256) {
        uint256 targetLtv = _depositTargetLtv();

        uint256 collateralPrice = COLLATERAL_ORACLE.price();
        uint256 debt = _debt();

        uint256 capFromNewCollateral = _maxBorrowFor(newCollateral, collateralPrice, targetLtv);
        uint256 totalDebtAtTarget = _maxBorrowFor(_collateral(), collateralPrice, targetLtv);
        uint256 capFromTargetDebt = Math.saturatingSub(totalDebtAtTarget, debt);
        return Math.min(capFromNewCollateral, capFromTargetDebt);
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

    function _debtInCollateralAsset() internal view returns (uint256) {
        return _debt().mulDiv(ORACLE_PRICE_SCALE, IOracle(COLLATERAL_ORACLE).price());
    }

    function _collateralInDebtAsset() internal view returns (uint256) {
        return _collateral().mulDiv(IOracle(COLLATERAL_ORACLE).price(), ORACLE_PRICE_SCALE);
    }

    function _debtInYieldAsset() internal view returns (uint256) {
        return _debt().mulDiv(ORACLE_PRICE_SCALE, IOracle(YIELD_ORACLE).price());
    }

    function _ltv() internal view returns (uint256) {
        uint256 coll = _collateral();
        if (coll == 0) {
            if (_debt() == 0) return 0;
            return type(uint256).max;
        }
        return _debtInCollateralAsset().mulDiv(LTV_SCALE, coll);
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
