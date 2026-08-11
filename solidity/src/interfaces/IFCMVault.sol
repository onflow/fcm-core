// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title IFCMVault
/// @author Flow Foundation
/// @notice Interface for the FCMVault
interface IFCMVault {
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

    /// @dev Deposits are frozen while a recovery is pending or after it executes.
    error EmergencyRecoveryActive();
    /// @dev `executeEmergencyRecovery` reverts before recovery is scheduled or before its delay elapses.
    error EmergencyRecoveryNotReady();
    /// @dev Thrown when a fee rate above its hard cap is set.
    error InvalidFee();
    /// @dev Thrown when a slippage tolerance >= 100% (10_000 bps) is set.
    error InvalidSlippage();
    /// @dev Deposit blocked while the vault is marked underwater with shares outstanding.
    error VaultUnderwater();

    /// @notice Emitted when a recovery is scheduled.
    /// @param caller Owner that scheduled it.
    /// @param validAt Timestamp the recovery becomes executable (`now + recoveryDelay`).
    event EmergencyRecoveryScheduled(address indexed caller, uint256 validAt);
    /// @notice Emitted when a pending recovery is cancelled before execution.
    /// @param caller Owner that cancelled it.
    event EmergencyRecoveryCancelled(address indexed caller);
    /// @notice Emitted when a recovery executes and the position is swept to the owner.
    /// @param debtRepaid Loan token the owner funded to clear the debt.
    /// @param collateralOut Collateral swept to the owner.
    /// @param yieldOut Yield token swept to the owner.
    /// @param loanOut Over-funded loan token remainder swept back to the owner.
    event EmergencyRecoveryExecuted(uint256 debtRepaid, uint256 collateralOut, uint256 yieldOut, uint256 loanOut);

    /// @notice Emitted when the admin updates the fee recipient (old + new).
    /// @param oldRecipient Previous fee recipient.
    /// @param newRecipient New fee recipient.
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when fees are accrued and shares minted to the recipient.
    /// @param recipient Account that received the minted fee shares.
    /// @param managementFee Management fee accrued this call, in asset terms.
    /// @param performanceFee Performance fee accrued this call, in asset terms.
    /// @param feeShares Shares minted to `recipient` (dilution).
    event FeesAccrued(address indexed recipient, uint256 managementFee, uint256 performanceFee, uint256 feeShares);

    /// @notice Emitted when the harvest leg of `rebalance` sells surplus yield and redeploys it as collateral.
    /// @param yieldSold Yield token sold (the surplus above debt backing).
    /// @param collateralAdded Collateral supplied from the swap proceeds.
    event Harvested(uint256 yieldSold, uint256 collateralAdded);
    /// @notice Emitted when the admin updates the management fee (old + new).
    /// @param oldBps Previous management fee rate, in basis points.
    /// @param newBps New management fee rate, in basis points.
    event ManagementFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the admin updates `maxSlippageBps`.
    /// @param oldBps Previous slippage tolerance, in basis points.
    /// @param newBps New slippage tolerance, in basis points.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted when the admin updates the TVL limit.
    /// @param previousMaxTvl Previous TVL limit.
    /// @param newMaxTvl New TVL limit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    /// @notice Emitted when the admin updates the performance fee (old + new).
    /// @param oldBps Previous performance fee rate, in basis points.
    /// @param newBps New performance fee rate, in basis points.
    event PerformanceFeeSet(uint256 oldBps, uint256 newBps);
    /// @notice Emitted whenever the vault is re-balanced
    /// @param caller Address that invoked `rebalance`.
    /// @param healthFactorBefore Health factor at the start of the call (WAD-scaled).
    /// @param healthFactorAfter Health factor after the rebalance (WAD-scaled).
    event Rebalanced(address indexed caller, uint256 healthFactorBefore, uint256 healthFactorAfter);
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
    /// @param debtPrice Loan-token price in loan token (the 1e36 scale).
    /// @param yieldPrice Yield-token price in loan token, 1e36-scaled.
    event VaultState(
        uint256 collateral, uint256 debt, uint256 yield, uint256 collateralPrice, uint256 debtPrice, uint256 yieldPrice
    );

    /// @notice Members of this role may deposit assets, hold shares, and transfer shares.
    function EARLY_ACCESS_ROLE() external view returns (bytes32);
    /// @notice Permissionlessly accrue fees up to the current block (mints fee shares to the recipient). Lets a keeper
    /// tick the management fee during idle stretches so it tracks NAV-over-time more closely.
    function accrueFees() external;

    /// @notice FlowSwap V3 asset/debt pool for the harvest loan->collateral leg. Its live `slot0` price is read to
    /// bound leg 2 to the market oracle, skipping when the pool is already past the slippage bound.
    function assetDebtPool() external view returns (address);
    /// @notice Cancel a pending recovery during its timelock window.
    function cancelEmergencyRecovery() external;
    /// @notice Execute a scheduled recovery once its timelock elapses. The owner funds the full debt in `loanToken`;
    /// the position is fully unwound (no swap, no oracle read) and all assets are swept to the owner. Burns no shares
    /// and permanently blocks deposits. `redeem` stays callable throughout the window so holders may exit first.
    /// @dev
    /// Oracle-independent by construction: fees are never accrued here (no NAV mark), and `repayAll` zeroes the debt
    /// before `withdrawCollateral`, so Morpho's health check short-circuits on `borrowShares == 0` without reading its
    /// oracle. Recovery stays executable when oracles are bricked.
    function executeEmergencyRecovery() external;
    /// @notice Pool fee tier for the asset/debt pool, used to reconcile redeem surplus from loan token back to the
    /// underlying asset.
    function feeAssetDebt() external view returns (uint24);
    /// @notice Recipient of minted fee shares. Must hold `EARLY_ACCESS_ROLE` to receive them; if unset or not
    /// allowlisted, fee accrual is skipped (never reverts) so core flows can't be bricked.
    function feeRecipient() external view returns (address);
    /// @notice Pool fee tier for the yield/debt pool used in rebalance swaps.
    /// @dev Pool fee for swapping yield<->debt.
    function feeYieldDebt() external view returns (uint24);
    /// @notice Health factor above which `rebalance` will lever up (borrow more debt and swap to yield). The position
    /// is under-levered above this bound. WAD-scaled.
    function healthFactorMax() external view returns (uint256);
    /// @notice Re-entry target for a lever-up: when `hf > healthFactorMax`, `rebalance` borrows just enough to lower
    /// the health factor to this value, which sits just below the upper bound. WAD-scaled. The four health factors must
    /// satisfy `WAD <= healthFactorMin <= healthFactorMinTarget <= healthFactorMaxTarget <= healthFactorMax`.
    function healthFactorMaxTarget() external view returns (uint256);
    /// @notice Health factor below which `rebalance` will delever (sell yield to repay debt). The position is
    /// over-levered below this bound. WAD-scaled.
    function healthFactorMin() external view returns (uint256);
    /// @notice Re-entry target for a delever: when `hf < healthFactorMin`, `rebalance` repays just enough debt to raise
    /// the health factor to this value, which sits just above the lower bound. Landing here rather than exactly on
    /// `healthFactorMin` leaves a small margin so routine drift does not immediately re-trigger. WAD-scaled.
    function healthFactorMinTarget() external view returns (uint256);
    /// @notice Timestamp of the last fee accrual, for the time-based management fee.
    function lastFeeAccrual() external view returns (uint256);
    /// @notice Address of the loan token (inner vault asset).
    /// @dev The loan token is the inner vault's asset and the debt leg of the position.
    function loanToken() external view returns (IERC20);

    // ── Management & performance fees
    /// @notice Flat yearly management fee on NAV, in basis points. 0 = off.
    /// @dev Linear accrual of the annual rate; bounded by the 10% cap.
    function managementFeeBps() external view returns (uint256);

    /// @notice The Morpho Blue market parameters the vault operates on.
    /// @return loanToken The market's loan token address.
    /// @return collateralToken The market's collateral token address.
    /// @return oracle The market's oracle address.
    /// @return irm The market's interest rate model address.
    /// @return lltv The market's loan-to-value ratio, WAD-scaled.
    function market()
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
    /// @notice Max price impact (basis points) tolerated on the rebalance swaps (lever and delever). It sets each
    /// swap's `sqrtPriceLimitX96` to the oracle price discounted by this amount, so the pool fills only while its
    /// marginal price stays within tolerance and partial-fills (or skips) past it — rather than reverting. Bounds
    /// price impact, not the pool's fixed LP fee. Applies only to vault-initiated rebalances — deposit/redeem
    /// slippage is the caller's responsibility, set via the ERC4626 router. Defaults to 1%, admin-adjustable.
    function maxSlippageBps() external view returns (uint256);
    /// @notice TVL limit, denominated in the vault's Asset token. Enforced by `super.deposit`, which reverts with
    /// `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`. Default 0 -> no deposits until admin raises
    /// it.
    /// - This constraint prevents all deposits/mints which would cause the vault to exceed the configured TVL limit
    ///   after the deposit/mint completes.
    /// - This constraint does not prevent any withdrawals/redeems under any circumstances.
    /// - This constraint does not prevent the vault from holding more assets than its configured TVL.
    /// This can happen if:
    /// - The owner sets maxTvl to a value lower than the current totalAssets
    /// - The value of vault holdings increases above the TVL limit due to market conditions. This can occur without
    ///   any direct interactions with the vault.
    function maxTvl() external view returns (uint256);
    /// @notice High-water mark for the performance fee, as asset-per-share scaled by WAD (`NAV * WAD / claims`).
    /// Flow-neutral, strict all-time peak. Vault-wide (one mark for all holders): a depositor entering below it rides
    /// the recovery back up fee-free — accepted by design in lieu of per-user-HWM accounting.
    function perfHighWaterMark() external view returns (uint256);
    /// @notice Performance fee on per-share gains above the high-water mark, in basis points. 0 = off.
    /// @dev Crystallizes on UNREALIZED, oracle-marked NAV and is triggerable by anyone via `accrueFees`; bounded by the
    /// all-time HWM and the 50% cap.
    function performanceFeeBps() external view returns (uint256);
    /// @notice Drive the vault's leveraged Morpho position back inside the `[healthFactorMin, healthFactorMax]` band
    /// and realize surplus yield above the yield-factor band.
    /// @dev Two legs: `_harvest` (realize surplus) then
    /// `_adjustLeverage` (restore the band).
    function rebalance() external;

    // ── Timelocked emergency recovery (custodial, in-kind) ──────────────────

    /// @notice Delay (in seconds) between scheduling and executing a recovery.
    function recoveryDelay() external view returns (uint256);
    /// @notice Timestamp a scheduled recovery becomes executable; 0 = none pending.
    function recoveryValidAt() external view returns (uint256);
    /// @notice Set once a recovery executes; permanently blocks new deposits.
    function recovered() external view returns (bool);

    /// @notice Escape hatch — swap-free, in-kind redemption: the caller repays `owner`'s pro-rata debt slice in
    /// `loanToken` and burns `owner`'s `shares`; `receiver` receives the pro-rata collateral and yield tokens directly.
    /// Needs no swap — the yield leg is delivered in kind rather than sold on the AMM; the collateral leg still
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
    /// @notice Schedule a timelocked emergency recovery. Executable after `recoveryDelay`; the owner may cancel in the
    /// meantime.
    function scheduleEmergencyRecovery() external;
    /// @notice Set the fee recipient. Accrues to the old recipient first.
    /// @dev The recipient must hold `EARLY_ACCESS_ROLE` to receive minted fee shares; if it doesn't, accrual silently
    /// skips (see `_accrueFees`).
    /// @param newRecipient New fee recipient address.
    function setFeeRecipient(address newRecipient) external;
    /// @notice Set the management fee rate (basis points), capped at `MAX_MANAGEMENT_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    /// @param newBps New management fee rate in basis points.
    function setManagementFeeBps(uint256 newBps) external;
    /// @notice Set the max slippage tolerance applied to the rebalance swaps.
    /// @param newBps Tolerance in basis points; must be < 100% (10_000) so the floor can never be fully disabled.
    function setMaxSlippageBps(uint256 newBps) external;
    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    /// @param newMaxTvl the new TVL limit; applies only to new deposits.
    function setMaxTvl(uint256 newMaxTvl) external;
    /// @notice Set the performance fee rate (basis points), capped at `MAX_PERFORMANCE_FEE_BPS`.
    /// @dev Accrues at the OLD rate first so the change isn't retroactive.
    /// @param newBps New performance fee rate in basis points.
    function setPerformanceFeeBps(uint256 newBps) external;
    /// @notice The FlowSwap V3 yield/debt pool the rebalance swaps route through. Read for its live `slot0` marginal
    /// price so a rebalance can derive a `sqrtPriceLimitX96` from the oracle and skip when the pool is already priced
    /// past the slippage bound.
    function yieldDebtPool() external view returns (address);
    /// @notice The yield factor is `yieldValue / debt`, WAD-scaled (WAD = the yield exactly repays the debt). It is NOT
    /// a yield rate. `yieldFactorMax` is the upper edge of its band: `rebalance`'s harvest leg fires only when the
    /// yield factor exceeds it, so it does not act on sub-threshold surplus. Must be `>= WAD`. Immutable, like the
    /// health-factor band bounds.
    function yieldFactorMax() external view returns (uint256);
    /// @notice Address of the oracle for the yield token.
    /// @dev We will deploy an oracle instance, which will provide the best available price information for the given
    /// token. This may be a 3rd party oracle, onchain price information, or both.
    function yieldOracle() external view returns (address);
    /// @notice Address of the yield token (inner vault share).
    /// @dev The yield token is the inner vault's share token and the yield leg of the position.
    function yieldToken() external view returns (IERC20);

    /// @notice Returns the vault's net asset value (NAV) denominated in the underlying asset (collateral token).
    /// @dev NAV = collateral + yield − debt, with both yield and debt converted into asset units using oracle prices:
    /// - collateral: read directly from the Morpho position.
    /// - yield: balance of `yieldToken` held by the vault, priced through `yieldOracle` and the market oracle
    ///   (see `_yieldToAsset`).
    /// - debt: outstanding loan-token debt on the Morpho market, valued at the market oracle price
    ///   (see `MarketLib.debt`).
    /// Returns 0 if debt exceeds gross value (an underwater position). This is a stale read by default — callers that
    /// need an up-to-the-block NAV must accrue interest on the market in the same tx first (see `deposit`).
    /// @return totalManagedAssets The vault's net asset value in underlying asset units.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Remaining headroom under the TVL limit, clamped to 0 when deposits are disabled.
    /// @param receiver The account that would receive the deposited shares.
    /// @return maxAssets Maximum depositable asset amount.
    /// @dev Even if the inner vault has hit its own deposit limit, we may still be able to obtain shares of it on the
    /// AMM to satisfy the deposit. However, if we implement 'direct deposit' to the inner vault, its own maxDeposit()
    /// will bind.
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Deposit `assets` of the underlying asset into the vault and mint vault shares to `receiver`.
    /// @dev Expansion sequence (see docs/architecture.md §A). Let `navBefore` be the vault NAV before this deposit:
    /// 1. Accrue market interest so `navBefore` and the post-deposit NAV measurement are both fresh.
    /// 2. Pull `assets` from the caller and supply them as collateral to the Morpho market.
    /// 3. Borrow `toBorrow = _targetBorrowAgainst(assets)` loan token and swap it into yield token on FlowSwap V3.
    ///    The borrow is capped so this deposit cannot drag the existing position's health factor down to the target
    ///    — small deposits never rebalance the whole protocol.
    /// 4. Mint shares pro-rata to the NAV contribution Rounding favors the vault: the share computation rounds down,
    ///    so any residual NAV accrues to existing shareholders rather than the new depositor.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Account to credit with newly minted shares.
    /// @return shares Vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Not implemented. Use `deposit` instead.
    /// @dev `mint` would need to invert the borrow-and-swap leg to solve for the asset input that produces an exact
    /// share output — non-trivial because the yield leg goes through an AMM whose realized price is only known after
    /// execution.
    /// @param shares Vault shares to mint (unused — always reverts).
    /// @param receiver Account that would receive the shares (unused — always reverts).
    /// @return assets Asset amount (unused — always reverts).
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Not implemented. Use `redeem` instead; `maxWithdraw` reports 0.
    /// @param assets Asset amount to withdraw (unused — always reverts).
    /// @param receiver Account that would receive the asset (unused — always reverts).
    /// @param owner Account whose shares would be burned (unused — always reverts).
    /// @return shares Vault shares burned (unused — always reverts).
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeem `shares` of this vault for the underlying asset. The owner's shares are burned, a proportional
    /// slice of the underlying leveraged position is unwound through the AMM, and the resulting asset is delivered to
    /// `receiver`.
    /// @dev Unwind sequence (AMM-mediated, see docs/architecture.md §A). Let `p = shares / _totalClaims()`, the
    /// redeemed fraction of the total claim pool (existing supply + virtual-share offset), and `d* = p × debt`, the
    /// pro-rata debt slice. The unwind:
    /// 1. Sell exactly `p × yieldToken` for loanToken on FlowSwap V3. Call the realized loanToken output `loanGot`.
    /// 2. If `loanGot >= d*` (Case A - fair or favorable AMM execution): repay `d*`, withdraw `p * collateral` of the
    ///    asset, and swap the surplus `loanGot - d*` loanToken to the asset.
    /// 3. If `loanGot < d*` (Case B - yield underperformed): flash-borrow the shortfall `d* - loanGot` in loanToken,
    ///    repay the full `d*`, withdraw the full `p * collateral`, and sell just enough of that collateral to repay the
    ///    flash loan. The redeemer takes home their full pro-rata value; the collateral sold covers the debt the
    ///    yield leg could not.
    /// 4. Burn shares and transfer the new asset balance to receiver.
    ///
    /// Rounding favors the vault: all pro-rata slices round down, so residuals accrue to remaining shareholders rather
    /// than leaking to the redeemer.
    /// Reverts if `msg.sender != owner` and allowance is insufficient.
    /// @param shares Vault shares to burn.
    /// @param receiver Account to credit with the asset payout.
    /// @param owner Account whose shares are burned.
    /// @return assets Asset actually delivered to `receiver`.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Withdraw is disabled in favor of redeem.
    /// @param owner Account whose shares would be burned.
    /// @return maxAssets Always 0.
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Mint is disabled in favor of deposit.
    /// @param receiver Account that would receive the shares.
    /// @return maxShares Always 0.
    function maxMint(address receiver) external view returns (uint256 maxShares);

    // function convertToShares(uint256 assets) external view returns (uint256 shares);
    // function convertToAssets(uint256 shares) external view returns (uint256 assets);
    // function asset() external view returns (address assetTokenAddress);
    // function maxRedeem(address owner) external view returns (uint256 maxShares);
    // function previewRedeem(uint256 shares) external view returns (uint256 assets);
    // function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    // function previewMint(uint256 shares) external view returns (uint256 assets);
    // function previewDeposit(uint256 assets) external view returns (uint256 shares);
}
