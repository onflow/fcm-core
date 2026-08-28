// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "./external/IUniswapV3Pool.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title IFCMVault
/// @author Flow Foundation
/// @notice Interface for the FCMVault
interface IFCMVault is IERC4626 {
    struct InitParams {
        address collateralToken;
        address loanToken;
        address yieldToken;

        uint128 ltvMin;
        uint128 ltvMax;

        address collateralLoanPool;
        address yieldLoanPool;

        address collateralOracle;
        address marketIrm;
        uint256 marketLltv;
        address yieldOracle;
        address morpho;

        string name;
        string symbol;
        address owner;
    }

    /// @notice Emitted when an emergency recovery is scheduled.
    /// @param validAt Timestamp the emergency recovery becomes executable (`now + 7 days`).
    event EmergencyRecoveryScheduled(uint256 validAt);
    /// @notice Emitted when a pending emergency recovery is cancelled before execution.
    event EmergencyRecoveryCancelled();
    /// @notice Emitted when an emergency recovery executes and the position is swept to the owner.
    /// @param collateralOut The amount of collateral tokens swept to the owner.
    /// @param yieldOut The amount of yield tokens swept to the owner.
    /// @param loanOut The amount of unaccounted loan tokens swept to the owner.
    event EmergencyRecoveryExecuted(uint256 collateralOut, uint256 yieldOut, uint256 loanOut);

    /// @notice Emitted when the owner updates the fee recipient.
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when fees are accrued and shares minted to the recipient.
    /// @param managementFee Management fee accrued this call, in asset terms.
    /// @param performanceFee Performance fee accrued this call, in asset terms.
    /// @param feeShares Shares minted to `recipient` (dilution).
    event FeesAccrued(uint256 managementFee, uint256 performanceFee, uint256 feeShares);

    /// @notice Emitted when the owner updates the management fee.
    event ManagementFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the owner updates `maxSlippageBps`.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the owner updates the TVL limit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    /// @notice Emitted when the owner updates the performance fee.
    event PerformanceFeeSet(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when `rebalance` levers up (borrows loan, buys yield).
    event RebalancedUp(address indexed sender, uint256 loanBorrowed, uint256 yieldBought);
    /// @notice Emitted when `rebalance` delevers (sells yield, repays loan).
    event RebalancedDown(address indexed sender, uint256 yieldSold, uint256 loanRepaid);
    /// @notice Emitted when `harvest` sells surplus yield for collateral.
    event Harvested(address indexed sender, uint256 yieldSold, uint256 collateralAdded);
    /// @notice Emitted on a `redeemInKind`: `owner`'s `shares` burned, `sender` repaid `debtRepaid` loanToken,
    /// `receiver` got `collateralOut` collateral + `yieldOut` yield in kind.
    event RedeemInKind(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 debtRepaid,
        uint256 collateralOut,
        uint256 yieldOut,
        uint256 shares
    );
    /// @notice Emitted at the end of every state-modifying entry point with a snapshot of the vault's three legs and
    /// their oracle prices. All prices are quoted in loan-token (debt) units and 1e36-scaled.
    event VaultState(uint256 collateral, uint256 debt, uint256 yield, uint256 collateralPrice, uint256 yieldPrice);
    /// @notice Emitted when early access is granted to an account.
    event EarlyAccessGranted(address indexed account);
    /// @notice Emitted when early access is revoked from an account.
    event EarlyAccessRevoked(address indexed account);

    /// @notice Thrown when despositing more assets than the remaining headroom.
    error ERC4626ExceededMaxDeposit(uint256 assets, uint256 headroom);
    /// @notice Thrown when performing an action that is not allowed while a recovery is pending.
    error EmergencyRecoveryActive();
    /// @notice Thrown when executing a recovery that is not ready.
    error EmergencyRecoveryNotReady();
    /// @notice Thrown when setting a fee rate above its maximum allowed value.
    error MaxFeeRateExceeded();
    /// @notice Thrown when setting a slippage tolerance above the maximum allowed value.
    error MaxSlippageExceeded();
    /// @notice Thrown when depositing while the vault is underwater.
    error VaultUnderwater();
    /// @notice Thrown when the sender is not authorized to perform the action.
    error Unauthorized();
    /// @notice Thrown when an account without early access attempts to perform an action that requires early access.
    error NoEarlyAccess(address account);
    /// @notice Thrown when calling ERC4626 functionality that is unsupported in FCMVault.
    error NotImplemented();
    /// @notice Thrown when an input address is set to address(0).
    error ZeroAddress();
    /// @notice Thrown when the LTV band is invalid or `ltvMax >= MARKET_LLTV`.
    error InvalidLtv();
    /// @notice Thrown when unaccounted loan tokens remain in the vault.
    error LeftoverLoanTokens();
    /// @notice Thrown when redeeming while the vault is underwater.
    error VaultUnhealthy();

    /// @notice Permissionlessly accrue fees up to the current block.
    /// @dev Lets a keeper tick the management fee during idle stretches so it tracks NAV-over-time more closely.
    function accrueFees() external;
    /// @notice Drive the vault's leveraged Morpho position back inside the `[LTV_MIN, LTV_MAX]` band.
    /// @dev Borrows loan tokens from Morpho and swaps them for yield tokens on the AMM or vice versa.
    function rebalance() external;
    /// @notice Harvest surplus yield into collateral, back to 100% collateral/asset exposure.
    /// @dev Swaps extra yield tokens for collateral tokens on the AMM.
    /// @param maximumYield Maximum yield tokens to sell in this harvest.
    function harvest(uint256 maximumYield) external;

    /// @notice Schedule a timelocked emergency recovery. Executable after `recoveryDelay`
    function scheduleEmergencyRecovery() external;
    /// @notice Cancel a pending recovery during its timelock window.
    /// @dev Its not possible to cancel after the emergency recovery has been executed.
    function cancelEmergencyRecovery() external;
    /// @notice Execute a scheduled recovery once its timelock elapses.
    /// @dev WARNING: Must have repaid the full debt externally, must be done atomically to prevent frontrunning!
    /// @dev The position is fully unwound and all assets are swept to the owner. Oracle-independent by construction:
    /// fees are never accrued here (no NAV mark), and `withdrawCollateral` after the debt is cleared short-circuits
    /// Morpho's health check.
    function executeEmergencyRecovery() external;

    /// @notice Swap-free, in-kind redemption: the sender repays `owner`'s pro-rata debt slice in `loanToken` and burns
    /// `owner`'s `shares`; `receiver` receives the pro-rata collateral and yield tokens directly.
    /// @dev needs prior approval for the debt slice from the sender
    /// @dev Not oracle-free: fee accrual runs on entry and marks NAV via the yield and market oracles
    /// @param shares Vault shares to burn.
    /// @param receiver Account credited with the collateral + yield in kind.
    /// @param owner Account whose shares are burned and whose pro-rata debt the sender repays.
    /// @return collateralOut Collateral tokens delivered to `receiver`.
    /// @return yieldOut Yield tokens delivered to `receiver`.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        returns (uint256 collateralOut, uint256 yieldOut);

    /// @notice Set the fee recipient. Accrues to the old recipient first.
    /// @dev The recipient must have early access to receive minted fee shares; if not, accrual silently skips.
    function setFeeRecipient(address newRecipient) external;
    /// @notice Set the management fee rate (basis points), capped at `MAX_MANAGEMENT_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    function setManagementFeeBps(uint16 newBps) external;
    /// @notice Set the performance fee rate (basis points), capped at `MAX_PERFORMANCE_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    function setPerformanceFeeBps(uint16 newBps) external;
    /// @notice Set the max slippage tolerance applied to the rebalance swaps.
    function setMaxSlippageBps(uint16 newBps) external;
    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    function setMaxTvl(uint256 newMaxTvl) external;
    /// @notice Grant early access to an account.
    function grantEarlyAccess(address account) external;
    /// @notice Revoke early access from an account.
    function revokeEarlyAccess(address account) external;

    /// @notice Address of the immutable collateral token.
    /// @dev The collateral token is the asset of the ERC4626 vault.
    function COLLATERAL_TOKEN() external view returns (IERC20);
    /// @notice Address of the immutable loan token (inner vault asset).
    /// @dev The loan token is the inner vault's asset and the debt leg of the position.
    function LOAN_TOKEN() external view returns (IERC20);
    /// @notice Address of the immutable yield token (inner vault share).
    /// @dev The yield token is the inner vault's share token and the yield leg of the position.
    function YIELD_TOKEN() external view returns (IERC20);

    /// @notice Minimum LTV below which `rebalance` levers up (borrows more debt and swaps to yield). The position is
    /// under-levered below this bound.
    /// @dev 1e18-scaled.
    function LTV_MIN() external view returns (uint128);
    /// @notice Maximum LTV above which `rebalance` delevers (sells yield to repay debt). The position is over-levered
    /// above this bound.
    /// @dev 1e18-scaled.
    function LTV_MAX() external view returns (uint128);

    /// @notice Collateral/loan pool for swapping collateral to loan token or vice versa.
    function COLLATERAL_LOAN_POOL() external view returns (IUniswapV3Pool);
    /// @notice Fee tier for the collateral/loan pool.
    function COLLATERAL_LOAN_POOL_FEE() external view returns (uint24);
    /// @notice Loan/yield pool for swapping loan token to yield token or vice versa.
    function YIELD_LOAN_POOL() external view returns (IUniswapV3Pool);
    /// @notice Fee tier for the loan/yield pool.
    function YIELD_LOAN_POOL_FEE() external view returns (uint24);

    /// @notice Address of the Morpho Blue singleton.
    function MORPHO() external view returns (IMorpho);
    /// @notice Address of the oracle for the market.
    function COLLATERAL_ORACLE() external view returns (IOracle);
    /// @notice Address of the interest rate model for the market.
    function MARKET_IRM() external view returns (address);
    /// @notice Loan-to-value ratio for the market, 1e18-scaled.
    function MARKET_LLTV() external view returns (uint256);
    /// @notice Address of the oracle for the yield token.
    function YIELD_ORACLE() external view returns (IOracle);

    /// @notice Delay (in seconds) between scheduling and executing a recovery.
    function EMERGENCY_RECOVERY_DELAY() external view returns (uint32);
    /// @notice Timestamp a scheduled recovery becomes executable; 0 = none pending.
    function emergencyRecoveryValidAt() external view returns (uint64);
    /// @notice Set when a recovery is scheduled. Can be unset before the recovery is executed.
    function emergencyRecoveryActive() external view returns (bool);
    /// @notice Set once the recovery executes. Will never be unset after being set.
    function emergencyRecovered() external view returns (bool);

    /// @notice TVL limit, denominated in the vault's Asset/Collateral token.
    /// @dev Defaults to 0 at deploy time.
    /// @dev Prevents all deposits which would cause the vault to exceed the configured TVL limit.
    /// @dev Does not prevent any redeems under any circumstances.
    /// @dev Does not prevent the vault from holding more assets than its configured TVL. This can happen if:
    /// - The owner sets maxTvl to a value lower than the current totalAssets
    /// - The value of vault holdings increases above the TVL limit due to market conditions.
    function maxTvl() external view returns (uint256);
    /// @notice Max price impact (basis points) tolerated on the rebalance and harvest swaps.
    /// @dev Defaults to 0 at deploy time.
    /// @dev Swaps are limited to the maxSlippage.
    /// @dev Does not limit the slippage of deposits and redeems. This is the sender's responsibility.
    function maxSlippageBps() external view returns (uint16);
    /// @notice Flat yearly management fee on NAV, in basis points.
    /// @dev Defaults to 0 at deploy time.
    /// @dev Linear accrual of the annual rate; bounded by the 10% cap.
    function managementFeeBps() external view returns (uint16);
    /// @notice Performance fee on per-share gains above the high-water mark, in basis points.
    /// @dev Defaults to 0 at deploy time.
    /// @dev Crystallizes on UNREALIZED, oracle-marked NAV, bounded by the all-time HWM and the 50% cap.
    function performanceFeeBps() external view returns (uint16);
    /// @notice Recipient of minted fee shares.
    /// @dev Must have early access to receive them
    /// @dev if unset or not allowlisted, fee accrual is skipped (never reverts) so core flows can't be bricked.
    function feeRecipient() external view returns (address);
    /// @notice Timestamp of the last fee accrual, for the time-based management fee.
    function lastFeeAccrual() external view returns (uint64);
    /// @notice High-water mark for the performance fee.
    /// @dev Scaled by 1e18 (`NAV * 1e18 / claims`).
    /// @dev Flow-neutral, strict all-time peak. Vault-wide (one mark for all holders): a depositor entering below it
    /// rides the recovery back up fee-free - accepted by design.
    function perfHighWaterMark() external view returns (uint256);
    /// @notice Mapping of addresses to their early access status.
    function earlyAccess(address account) external view returns (bool hasEarlyAccess);

    /// @notice The underlying asset managed by the vault (the collateral token).
    function asset() external view override(IERC4626) returns (address);
    /// @notice Returns the vault's net asset value (NAV) denominated in the underlying asset (collateral token).
    /// @dev NAV = collateral + yield - debt.
    /// @dev Returns 0 if debt exceeds gross value (an underwater position).
    /// @dev This is a stale read by default - senders that need an up-to-the-block NAV must accrue interest first.
    function totalAssets() external view override(IERC4626) returns (uint256 assets);
    /// @notice Convert an asset amount to the equivalent share amount at the current exchange rate.
    function convertToShares(uint256 assets) external view override(IERC4626) returns (uint256 shares);
    /// @notice Convert a share amount to the equivalent asset amount at the current exchange rate.
    function convertToAssets(uint256 shares) external view override(IERC4626) returns (uint256 assets);
    /// @notice Remaining headroom under the TVL limit, clamped to 0 when deposits are disabled.
    function maxDeposit(address receiver) external view override(IERC4626) returns (uint256 maxAssets);
    /// @notice Deposit `assets` of the underlying into the vault and mint vault shares to `receiver`. The assets are
    /// supplied as collateral to Morpho, a loan is borrowed at the deposit-target LTV and swapped into yield, and
    /// shares are minted in proportion to the depositor's contribution to NAV.
    /// @dev WARNING: Standard ERC-4626 deposit does not provide slippage protection. Direct calls are vulnerable to
    /// sandwich attacks; call via a router enforcing `minSharesOut`.
    /// @return shares Vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) external override(IERC4626) returns (uint256 shares);
    /// @notice Maximum redeemable shares for `owner`.
    /// @dev While the vault is healthy, the owner can redeem all their shares.
    /// When the vault is unhealthy no shares can be redeemed.
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    /// @notice Redeem `shares` of this vault for the underlying asset. The owner's shares are burned, a proportional
    /// slice of the underlying leveraged position is unwound through the AMM, and the resulting asset is delivered to
    /// `receiver`.
    /// @dev WARNING: Standard ERC-4626 redeem does not provide slippage protection. Direct calls are vulnerable to
    /// sandwich attacks; call via a router enforcing `minAssetsOut`.
    /// @dev Reverts with `VaultUnhealthy` if the position's LTV exceeds `LTV_MAX`.
    /// @return assets Asset actually delivered to `receiver`.
    function redeem(uint256 shares, address receiver, address owner)
        external
        override(IERC4626)
        returns (uint256 assets);

    /// @notice Not implemented - always reverts.
    /// @dev Preview is not supported because the realized deposit output depends on AMM execution unknown before the
    /// swap runs.
    function previewDeposit(uint256 assets) external pure override(IERC4626) returns (uint256 shares);
    /// @notice Mint is disabled in favor of deposit. Always returns 0.
    function maxMint(address receiver) external pure override(IERC4626) returns (uint256 maxShares);
    /// @notice Not implemented - always reverts. `mint` is disabled in favor of `deposit`.
    function previewMint(uint256 shares) external pure override(IERC4626) returns (uint256 assets);
    /// @notice Not implemented. Use `deposit` instead.
    function mint(uint256 shares, address receiver) external pure override(IERC4626) returns (uint256 assets);
    /// @notice Withdraw is disabled in favor of redeem. Always returns 0.
    function maxWithdraw(address owner) external pure override(IERC4626) returns (uint256 maxAssets);
    /// @notice Not implemented - always reverts. `withdraw` itself is disabled in favor of `redeem`.
    function previewWithdraw(uint256 assets) external pure override(IERC4626) returns (uint256 shares);
    /// @notice Not implemented. Use `redeem` instead.
    function withdraw(uint256 assets, address receiver, address owner)
        external
        pure
        override(IERC4626)
        returns (uint256 shares);

    /// @notice Not implemented - always reverts.
    /// @dev Preview is not supported because the realized redeem output depends on AMM execution unknown before the
    /// swap runs.
    function previewRedeem(uint256 shares) external pure override(IERC4626) returns (uint256 assets);
}
