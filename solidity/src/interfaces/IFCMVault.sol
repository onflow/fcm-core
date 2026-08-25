// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ISwapRouter02} from "./external/ISwapRouter02.sol";
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
        address swapRouter;

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

    /// @notice Emitted when the owner updates the fee recipient (old + new).
    /// @param oldRecipient Previous fee recipient.
    /// @param newRecipient New fee recipient.
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when fees are accrued and shares minted to the recipient.
    /// @param managementFee Management fee accrued this call, in asset terms.
    /// @param performanceFee Performance fee accrued this call, in asset terms.
    /// @param feeShares Shares minted to `recipient` (dilution).
    event FeesAccrued(uint256 managementFee, uint256 performanceFee, uint256 feeShares);

    /// @notice Emitted when `harvest` sells surplus yield and redeploys it as collateral.
    /// @param yieldSold Yield token the pool actually consumed, which is less than the surplus offered when leg 1
    /// partial-fills against its price bound.
    /// @param collateralAdded Collateral supplied from the swap proceeds.
    event Harvested(uint256 yieldSold, uint256 collateralAdded);
    /// @notice Emitted when the owner updates the management fee (old + new).
    /// @param oldBps Previous management fee rate, in basis points.
    /// @param newBps New management fee rate, in basis points.
    event ManagementFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the owner updates `maxSlippageBps`.
    /// @param oldBps Previous slippage tolerance, in basis points.
    /// @param newBps New slippage tolerance, in basis points.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the owner updates the TVL limit.
    /// @param previousMaxTvl Previous TVL limit.
    /// @param newMaxTvl New TVL limit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    /// @notice Emitted when the owner updates the performance fee (old + new).
    /// @param oldBps Previous performance fee rate, in basis points.
    /// @param newBps New performance fee rate, in basis points.
    event PerformanceFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted whenever the vault is re-balanced.
    /// @param caller Address that invoked `rebalance`.
    event Rebalanced(address indexed caller);
    /// @notice Emitted on a `redeemInKind` (escape hatch): `owner`'s `shares` burned, `caller` repaid `debtRepaid`
    /// loanToken, `receiver` got `collateralOut` collateral + `yieldOut` yield in kind.
    /// @param caller Account that
    /// invoked `redeemInKind` (repays the debt slice).
    /// @param receiver Account credited with collateral + yield in kind.
    /// @param owner Account whose shares are burned.
    /// @param shares Vault shares burned.
    /// @param debtRepaid Loan token the caller repaid on `owner`'s behalf.
    /// @param collateralOut Collateral tokens delivered to `receiver`.
    /// @param yieldOut Yield tokens delivered to `receiver`.
    event RedeemInKind(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 shares,
        uint256 debtRepaid,
        uint256 collateralOut,
        uint256 yieldOut
    );
    /// @notice Emitted at the end of every state-modifying entry point with a snapshot of the vault's three legs and
    /// their oracle prices. All prices are quoted in loan-token (debt) units and 1e36-scaled, so `amount * price /
    /// 1e36` gives each leg's value in debt units. `debtPrice` is the 1e36 scale itself, since debt is already
    /// denominated in the loan token.
    /// @param collateral Collateral supplied to Morpho, raw token units.
    /// @param debt Outstanding loan-token debt, raw token units.
    /// @param yield Yield token held by the vault, raw token units.
    /// @param collateralPrice Collateral price in loan token, 1e36-scaled.
    /// @param yieldPrice Yield-token price in loan token, 1e36-scaled.
    event VaultState(uint256 collateral, uint256 debt, uint256 yield, uint256 collateralPrice, uint256 yieldPrice);
    /// @notice Emitted when early access is granted to an account.
    /// @param account The account that was granted early access.
    event EarlyAccessGranted(address indexed account);
    /// @notice Emitted when early access is revoked from an account.
    /// @param account The account that was revoked early access.
    event EarlyAccessRevoked(address indexed account);

    /// @dev Attempted to deposit more assets than the max amount for `receiver`.
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    /// @dev Deposits are frozen while a recovery is pending or after it executes.
    error EmergencyRecoveryActive();
    /// @dev `executeEmergencyRecovery` reverts before recovery is scheduled or before its delay elapses.
    error EmergencyRecoveryNotReady();
    /// @dev Thrown when a fee rate above its hard cap is set.
    error InvalidFee();
    /// @dev Thrown when a slippage tolerance above the hard cap (10%, 1_000 bps) is set.
    error InvalidSlippage();
    /// @dev Deposit blocked while the vault is marked underwater with shares outstanding.
    error VaultUnderwater();
    /// @dev Thrown when `onMorphoRepay` is called by an address other than Morpho.
    error Unauthorized();
    /// @dev Thrown when an account without early access attempts to perform an action that requires early access.
    /// @param account The address without early access, can be receiver or sender.
    error NoEarlyAccess(address account);
    /// @dev Thrown when calling ERC4626 functionality that is unsupported in FCMVault.
    error NotImplemented();
    /// @notice Thrown when an input address is set to address(0).
    error ZeroAddress();
    /// @dev Thrown when the LTV band is invalid or `ltvMax >= MARKET_LLTV`.
    error InvalidLtv();
    /// @dev Thrown when `yieldToLoanMax < 1e18`.
    error InvalidYieldFactor();
    /// @notice Thrown when a harvest realizes more loan token than the outstanding debt can absorb, which would leave
    /// the excess idle and uncounted by `totalAssets`.
    error LeftoverLoanTokens();
    /// @notice Thrown during redeem when the vault is unhealthy.
    error VaultUnhealthy();

    /// @notice Permissionlessly accrue fees up to the current block (mints fee shares to the recipient). Lets a keeper
    /// tick the management fee during idle stretches so it tracks NAV-over-time more closely.
    function accrueFees() external;
    /// @notice Drive the vault's leveraged Morpho position back inside the `[LTV_MIN, LTV_MAX]` band.
    /// @dev Leverage adjustment only; harvest is a separate entry point.
    function rebalance() external;
    /// @notice Harvest surplus yield into collateral. Separate from `rebalance` so the keeper can control the maximum
    /// yield sold per call.
    /// @param maximumYield Maximum yield tokens to sell in this harvest.
    function harvest(uint256 maximumYield) external;

    /// @notice Schedule a timelocked emergency recovery. Executable after `recoveryDelay`; the owner may cancel in the
    /// meantime.
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

    /// @notice Escape hatch - swap-free, in-kind redemption: the caller repays `owner`'s pro-rata debt slice in
    /// `loanToken` and burns `owner`'s `shares`; `receiver` receives the pro-rata collateral and yield tokens directly.
    /// Needs no swap - the yield leg is delivered in kind rather than sold on the AMM; the collateral leg still
    /// settles through Morpho. The slice math is pure `shares/claims` arithmetic and reads no price, but the function
    /// is still not oracle-free: fee accrual runs on entry and marks NAV via the yield and market oracles (see
    /// `_accrueFees`), so this exit inherits their liveness. Rounding favors the vault: the debt slice rounds up,
    /// collateral/yield slices round down.
    /// Reverts if `msg.sender != owner` and allowance is insufficient, if the caller has not approved this vault for
    /// the debt slice, if the position is underwater (Morpho blocks the collateral withdrawal), or if an oracle read
    /// reverts during fee accrual.
    /// @param shares Vault shares to burn.
    /// @param receiver Account credited with the collateral + yield in kind.
    /// @param owner Account whose shares are burned and whose pro-rata debt the caller repays.
    /// @return collateralOut Collateral tokens delivered to `receiver`.
    /// @return yieldOut Yield tokens delivered to `receiver`.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        returns (uint256 collateralOut, uint256 yieldOut);

    /// @notice Set the fee recipient. Accrues to the old recipient first.
    /// @dev The recipient must have early access to receive minted fee shares; if not, accrual silently skips.
    /// @param newRecipient New fee recipient address.
    function setFeeRecipient(address newRecipient) external;
    /// @notice Set the management fee rate (basis points), capped at `MAX_MANAGEMENT_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    /// @param newBps New management fee rate in basis points.
    function setManagementFeeBps(uint16 newBps) external;
    /// @notice Set the performance fee rate (basis points), capped at `MAX_PERFORMANCE_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    /// @param newBps New performance fee rate in basis points.
    function setPerformanceFeeBps(uint16 newBps) external;
    /// @notice Set the max slippage tolerance applied to the rebalance swaps.
    /// @param newBps Tolerance in basis points; capped at 10% (1_000) so the floor can never be widened away.
    function setMaxSlippageBps(uint16 newBps) external;
    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    /// @param newMaxTvl the new TVL limit; applies only to new deposits.
    function setMaxTvl(uint256 newMaxTvl) external;
    /// @notice Grant early access to an account.
    /// @param account The account to grant early access to.
    function grantEarlyAccess(address account) external;
    /// @notice Revoke early access from an account.
    /// @param account The account to revoke early access from.
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

    /// @notice Address of the FlowSwap V3 SwapRouter02.
    function SWAP_ROUTER() external view returns (ISwapRouter02);
    /// @notice collateral/loan pool for swapping collateral to loan token or vice versa.
    function COLLATERAL_LOAN_POOL() external view returns (IUniswapV3Pool);
    /// @notice Pool fee tier for the collateral/loan pool.
    function COLLATERAL_LOAN_POOL_FEE() external view returns (uint24);
    /// @notice loan/yield pool for swapping loan token to yield token or vice versa.
    function YIELD_LOAN_POOL() external view returns (IUniswapV3Pool);
    /// @notice Pool fee tier for the loan/yield pool.
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

    // - Timelocked emergency recovery (custodial, in-kind) -----
    /// @notice Delay (in seconds) between scheduling and executing a recovery.
    function EMERGENCY_RECOVERY_DELAY() external view returns (uint32);
    /// @notice Timestamp a scheduled recovery becomes executable; 0 = none pending.
    function emergencyRecoveryValidAt() external view returns (uint64);
    /// @notice Set when a recovery is scheduled. Can be unset before the recovery is executed.
    function emergencyRecoveryActive() external view returns (bool);
    /// @notice Set once the recovery executes. Will never be unset after being set.
    function emergencyRecovered() external view returns (bool);

    // - Admin-controlled parameters & fees ---------
    /// @notice TVL limit, denominated in the vault's Asset/Collateral token. Enforced by `super.deposit`, which reverts
    /// with `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`. Default 0 -> no deposits until owner
    /// raises it.
    /// - This constraint prevents all deposits/mints which would cause the vault to exceed the configured TVL limit
    /// after the deposit/mint completes.
    /// - This constraint does not prevent any withdrawals/redeems under any circumstances.
    /// - This constraint does not prevent the vault from holding more assets than its configured TVL. This can happen
    /// if:
    ///   - The owner sets maxTvl to a value lower than the current totalAssets
    ///   - The value of vault holdings increases above the TVL limit due to market conditions. This can occur without
    ///     any direct interactions with the vault.
    function maxTvl() external view returns (uint256);
    /// @notice Max price impact (basis points) tolerated on the rebalance swaps (lever and delever). It sets each
    /// swap's `sqrtPriceLimitX96` to the oracle price discounted by this amount, so the pool fills only while its
    /// marginal price stays within tolerance and partial-fills (or skips) past it - rather than reverting. Bounds
    /// price impact, not the pool's fixed LP fee. Applies only to vault-initiated rebalances - deposit/redeem
    /// slippage is the caller's responsibility, set via the ERC4626 router. Defaults to 0 (off) at deploy time -
    /// rebalance/harvest swaps no-op until the owner sets a non-zero tolerance. Owner-adjustable.
    function maxSlippageBps() external view returns (uint16);
    /// @notice Flat yearly management fee on NAV, in basis points. 0 = off.
    /// @dev Linear accrual of the annual rate; bounded by the 10% cap.
    function managementFeeBps() external view returns (uint16);
    /// @notice Performance fee on per-share gains above the high-water mark, in basis points. 0 = off.
    /// @dev Crystallizes on UNREALIZED, oracle-marked NAV and is triggerable by anyone via `accrueFees`; bounded by the
    /// all-time HWM and the 50% cap.
    function performanceFeeBps() external view returns (uint16);
    /// @notice Recipient of minted fee shares. Must have early access to receive them; if unset or not allowlisted,
    /// fee accrual is skipped (never reverts) so core flows can't be bricked.
    function feeRecipient() external view returns (address);
    /// @notice Timestamp of the last fee accrual, for the time-based management fee.
    function lastFeeAccrual() external view returns (uint64);
    /// @notice High-water mark for the performance fee, as asset-per-share scaled by 1e18 (`NAV * 1e18 / claims`).
    /// Flow-neutral, strict all-time peak. Vault-wide (one mark for all holders): a depositor entering below it rides
    /// the recovery back up fee-free - accepted by design in lieu of per-user-HWM accounting.
    function perfHighWaterMark() external view returns (uint256);
    /// @notice Mapping of addresses to their early access status.
    /// @param account The address to check.
    /// @return hasEarlyAccess Whether the address has early access.
    function earlyAccess(address account) external view returns (bool hasEarlyAccess);

    // - IERC4626 overrides -------------
    // solhint-disable ordering, grouped by domain

    /// @notice The underlying asset managed by the vault (the collateral token).
    /// @return assetTokenAddress The collateral token address.
    function asset() external view override(IERC4626) returns (address assetTokenAddress);

    /// @notice Returns the vault's net asset value (NAV) denominated in the underlying asset (collateral token).
    /// @dev NAV = collateral + yield - debt, with both yield and debt converted into asset units using oracle prices:
    /// - collateral: read directly from the Morpho position.
    /// - yield: balance of `yieldToken` held by the vault, priced through `yieldOracle` and the market oracle
    /// (see `_yieldToCollateral`).
    /// - debt: outstanding loan-token debt on the Morpho market, valued at the market oracle price
    /// (see `MorphoLib.debt`).
    ///
    /// Returns 0 if debt exceeds gross value (an underwater position). This is a stale read by default - callers that
    /// need an up-to-the-block NAV must accrue interest on the market in the same tx first (see `deposit`).
    /// @return totalManagedAssets The vault's net asset value in underlying asset units.
    function totalAssets() external view override(IERC4626) returns (uint256 totalManagedAssets);

    /// @notice Convert an asset amount to the equivalent share amount at the current exchange rate.
    /// @param assets Amount of the underlying asset to convert.
    /// @return shares Equivalent vault shares.
    function convertToShares(uint256 assets) external view override(IERC4626) returns (uint256 shares);

    /// @notice Convert a share amount to the equivalent asset amount at the current exchange rate.
    /// @param shares Amount of vault shares to convert.
    /// @return assets Equivalent underlying asset amount.
    function convertToAssets(uint256 shares) external view override(IERC4626) returns (uint256 assets);

    /// @notice Remaining headroom under the TVL limit, clamped to 0 when deposits are disabled.
    /// @param receiver The account that would receive the deposited shares.
    /// @return maxAssets Maximum depositable asset amount.
    /// @dev Even if the inner vault has hit its own deposit limit, we may still be able to obtain shares of it on the
    /// AMM to satisfy the deposit. However, if we implement 'direct deposit' to the inner vault, its own maxDeposit()
    /// will bind.
    function maxDeposit(address receiver) external view override(IERC4626) returns (uint256 maxAssets);

    /// @notice Deposit `assets` of the underlying asset into the vault and mint vault shares to `receiver`.
    /// @dev WARNING: Standard ERC-4626 deposit does not provide slippage protection. Direct calls are vulnerable to
    /// sandwich attacks; call via a router enforcing `minSharesOut`.
    /// @dev The borrow is capped so this deposit cannot drag the existing position's LTV past the target - small
    /// deposits never rebalance the whole protocol.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Account to credit with newly minted shares.
    /// @return shares Vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) external override(IERC4626) returns (uint256 shares);

    /// @notice Maximum redeemable shares for `owner`. While the vault is healthy, the owner can redeem all their
    /// shares. When the vault is unhealthy no shares can be redeemed.
    /// @param owner Account whose redeemable shares are reported.
    /// @return maxShares The maximum redeemable shares for the owner.
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Redeem `shares` of this vault for the underlying asset. The owner's shares are burned, a proportional
    /// slice of the underlying leveraged position is unwound through the AMM, and the resulting asset is delivered to
    /// `receiver`.
    /// @dev WARNING: Standard ERC-4626 redeem does not provide slippage protection. Direct calls are vulnerable to
    /// sandwich attacks; call via a router enforcing `minAssetsOut`.
    /// @dev Unwind sequence (see docs/architecture.md):
    /// 1. Sell the pro-rata yield slice for loan token on FlowSwap V3.
    /// 2. Repay the pro-rata debt slice by borrow shares via Morpho's `onMorphoRepay` callback, which withdraws the
    /// pro-rata collateral slice and reconciles the realized swap output against the debt: selling collateral for any
    /// shortfall, or swapping surplus loan token back to collateral.
    /// 3. Burn shares and transfer the resulting collateral balance to `receiver`.
    ///
    /// Reverts with `VaultUnhealthy` if the position's LTV exceeds `LTV_MAX`.
    /// @param shares Vault shares to burn.
    /// @param receiver Account to credit with the asset payout.
    /// @param owner Account whose shares are burned.
    /// @return assets Asset actually delivered to `receiver`.
    function redeem(uint256 shares, address receiver, address owner)
        external
        override(IERC4626)
        returns (uint256 assets);

    // - IERC4626 not implemented -----------

    /// @notice Not implemented - always reverts. The realized share output depends on the borrow-and-swap leg whose
    /// AMM execution price is only known after the swap runs.
    /// @param assets Asset amount that would be deposited.
    /// @return shares Vault shares (unused - always reverts).
    function previewDeposit(uint256 assets) external pure override(IERC4626) returns (uint256 shares);

    /// @notice Mint is disabled in favor of deposit.
    /// @param receiver Account that would receive the shares.
    /// @return maxShares Always 0.
    function maxMint(address receiver) external pure override(IERC4626) returns (uint256 maxShares);

    /// @notice Not implemented - always reverts. `mint` is disabled in favor of `deposit`; preview follows.
    /// @param shares Vault shares that would be minted.
    /// @return assets Asset amount (unused - always reverts).
    function previewMint(uint256 shares) external pure override(IERC4626) returns (uint256 assets);

    /// @notice Not implemented. Use `deposit` instead.
    /// @dev `mint` would need to invert the borrow-and-swap leg to solve for the asset input that produces an exact
    /// share output - non-trivial because the yield leg goes through an AMM whose realized price is only known after
    /// execution.
    /// @param shares Vault shares to mint (unused - always reverts).
    /// @param receiver Account that would receive the shares (unused - always reverts).
    /// @return assets Asset amount (unused - always reverts).
    function mint(uint256 shares, address receiver) external pure override(IERC4626) returns (uint256 assets);

    /// @notice Withdraw is disabled in favor of redeem.
    /// @param owner Account whose shares would be burned.
    /// @return maxAssets Always 0.
    function maxWithdraw(address owner) external pure override(IERC4626) returns (uint256 maxAssets);

    /// @notice Not implemented - always reverts. `withdraw` itself is disabled in favor of `redeem`; preview follows.
    /// @param assets Asset amount that would be withdrawn.
    /// @return shares Vault shares (unused - always reverts).
    function previewWithdraw(uint256 assets) external pure override(IERC4626) returns (uint256 shares);

    /// @notice Not implemented. Use `redeem` instead; `maxWithdraw` reports 0.
    /// @param assets Asset amount to withdraw (unused - always reverts).
    /// @param receiver Account that would receive the asset (unused - always reverts).
    /// @param owner Account whose shares would be burned (unused - always reverts).
    /// @return shares Vault shares burned (unused - always reverts).
    function withdraw(uint256 assets, address receiver, address owner)
        external
        pure
        override(IERC4626)
        returns (uint256 shares);

    /// @notice Not implemented - always reverts. Preview is not supported because the realized redeem output depends
    /// on AMM execution unknown before the swap runs.
    /// @param shares Vault shares that would be redeemed.
    /// @return assets Asset amount (unused - always reverts).
    function previewRedeem(uint256 shares) external pure override(IERC4626) returns (uint256 assets);
}
