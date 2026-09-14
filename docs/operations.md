# Operations

Runbook for whoever deploys and owns an `FCMVault`. Everything here is derived from contract behaviour; none of it is enforced on-chain.

## A freshly deployed vault is inert

The constructor sets no operational parameters. Immediately after deployment:

| State               | Value at deploy | Effect                                                                                      |
| ------------------- | --------------- | ------------------------------------------------------------------------------------------- |
| `maxTvl`            | `0`             | Every `deposit` reverts `ExceededMaxDeposit`; `maxDeposit` is `0`.                          |
| `earlyAccess`       | empty           | Every mint and transfer reverts `NoEarlyAccess`.                                            |
| `maxSlippageBps`    | `0`             | Rebalance/harvest swaps skip unless the pool is already priced strictly better than fair.   |
| `feeRecipient`      | `address(0)`    | Fee accrual advances the clock but mints nothing.                                           |
| `managementFeeBps`  | `0`             | No management fee.                                                                          |
| `performanceFeeBps` | `0`             | No performance fee.                                                                         |
| `lastFeeAccrual`    | `0`             | Harmless — see "Fees never back-charge" below.                                              |

The `maxSlippageBps = 0` case is the subtle one. With a zero tolerance, `SwapLib.swapLimit` derives a price limit exactly equal to the oracle price and then skips the swap entirely unless the pool's spot is already strictly better than fair. The result is not a revert — it is a silent no-op, so `rebalance()` appears to succeed while doing nothing. **Set `maxSlippageBps` before relying on rebalancing.**

## Deployment checklist

The contract validates almost none of this. `ltvMin < ltvMax < marketLltv` and non-zero addresses are the extent of it — every parameter below is chosen, and owned, by whoever deploys the vault. Sensible values are a property of the specific collateral, yield source, and venue, not of the code, so nothing here can be a fixed recommendation.

Before the vault is announced or funded:

1. **Verify the market tuple.** `loanToken`, `collateralToken`, `collateralOracle`, `marketIrm`, `marketLltv` must hash to a Morpho market that actually exists. If it does not, every Morpho call reverts — the vault is dead on arrival rather than silently wrong, but confirm it up front.
2. **Verify the two pools** are the pools you intend to trade through, for the right token pairs. A mismatched pool cannot break the oracle-derived price bound, but it corrupts the go/skip decision and quietly degrades rebalancing.
3. **Size the yield/loan pool against the position, not against steady state.** It backs every rebalance and every standard `redeem`. The constraint that binds is crash-day throughput: how much the vault may need to sell in a single stressed session, while arbitrage restocking is slow. A stable/stable pair concentrates liquidity well, so this needs far less depth than a volatile pair would — but how much is enough depends on the collateral's volatility and the band width, and must be worked out per deployment.
4. **Verify the yield oracle** prices the yield token in _loan_ tokens, 1e36-scaled, and that its `CONVERSION_SAMPLE` is large enough that `convertToAssets` does not floor away meaningful precision.
5. **Check the band** against the market's LLTV. The constructor has no opinion on whether the headroom between `ltvMax` and `lltv` is enough to survive the collateral's volatility between rebalances, nor on whether the band is wide enough that ordinary price noise does not churn the position through avoidable swap fees. Both are volatility-dependent and should be modelled on the actual asset.
6. **`setMaxSlippageBps`** to a value reflecting genuine execution cost on the yield/loan pool. Too tight and rebalances no-op when they are most needed; too loose and every excursion subsidizes whoever triggers it. Hard cap is 1000 (10%).
7. **`grantEarlyAccess`** for the intended depositors — _and_ for `feeRecipient`, which must be allowlisted to receive minted fee shares.
8. **`setFeeRecipient`**, then `setManagementFeeBps` / `setPerformanceFeeBps`. Setting the recipient last is fine; the fee clock advances regardless and skipped periods are forgiven, not back-charged.
9. **`setMaxTvl`** last. This is the switch that opens deposits.
10. **Seed the position** and confirm a `rebalance()` and a `harvest()` both do real work before scaling up.

### Fees never back-charge

`lastFeeAccrual` starts at `0`, so a first accrual would compute an elapsed time of `block.timestamp` — clamped by the one-year cap to 365 days. That never turns into a retroactive bill, because both fee setters call `_accrueFees()` **before** writing the new rate: the clock is always pinned to "now" in the same transaction that first makes a rate nonzero, and the accrual it pins with runs at the old rate of `0`.

The performance high-water mark behaves the same way. It is seeded at the starting price-per-share so the first deposit is not counted as performance, and `_accrueFees()` ratchets it before `setPerformanceFeeBps` takes effect, so enabling the fee marks from the price at that moment rather than from deploy.

The corollary is that a period during which fees were configured but the mint was skipped — `feeRecipient` unset or de-allowlisted — is **forgiven, not deferred**. The clock and high-water mark advance regardless of whether shares were actually minted.

## Keeper duties

Both are permissionless, so a keeper is an availability optimization, not a trust dependency — anyone can call either if the keeper stalls.

- **`rebalance()`** — call whenever LTV leaves `[LTV_MIN, LTV_MAX]`. Takes no arguments and no-ops when in band, so over-calling is safe (it costs gas and nothing else). Watch the `RebalancedUp`/`RebalancedDown` events: a call that emits nothing was a no-op, and a call that emits a smaller amount than expected was a partial fill against the price bound.
- **`harvest(maximumYield)`** — call when the yield balance exceeds the debt valued in yield. Size `maximumYield` to what the _collateral/loan_ pool can absorb; oversizing reverts `LeftoverLoanTokens` and the whole call is wasted. Start small and increase.
- **`accrueFees()`** — optional. Ticking it during idle stretches makes the management fee track NAV-over-time more closely; skipping it just means fees meter from the next interaction.

`rebalance`, `harvest`, `deposit`, `redeem`, and `redeemInKind` each emit a `VaultState(collateral, debt, yield, collateralPrice, yieldPrice)` snapshot after the body runs — enough to reconstruct LTV and the harvest surplus off-chain without an RPC read. It fires even on a no-op call, so absence of the event means the transaction reverted, not that nothing happened.

## Emergency recovery

A one-way, 7-day-timelocked sweep of the entire position to the owner. Read [`security.md` § Owner trust](./security.md#owner-trust) before using it.

### Procedure

1. **`scheduleEmergencyRecovery()`.** Emits `EmergencyRecoveryScheduled(validAt)`. From this moment `deposit` and `harvest` revert, and `rebalance` will only delever. `redeem` and `redeemInKind` stay open — this window is holders' exit, and the whole point of the delay.
2. **Wait out `EMERGENCY_RECOVERY_DELAY` (7 days).** `cancelEmergencyRecovery()` is available for the entire window and restores normal operation.
3. **Repay the debt from outside the vault, and execute atomically.** `executeEmergencyRecovery` does _not_ repay anything itself, and Morpho refuses to release collateral while borrow shares are outstanding. The owner must repay the vault's Morpho debt on its behalf, and **bundle that repayment with `executeEmergencyRecovery()` in a single transaction** — a vault with cleared debt and full collateral sitting between two transactions is exposed to anyone calling `rebalance()` to re-lever it, or worse.

### After execution

`emergencyRecovered` is set permanently. There is no path that clears it.

- All collateral, yield, and loan-token balances are now at `owner()`.
- `redeem`, `redeemInKind`, and `rebalance` revert forever. `maxRedeem` returns `0`.
- `cancelEmergencyRecovery` reverts.
- Shares remain transferable between allowlisted holders but have no on-chain claim on anything.

Distribution to holders is entirely off-chain and at the owner's discretion. **Plan and communicate that process before executing, not after.**

## Monitoring

Minimum viable alerting:

| Signal                                  | Why                                                                                                |
| --------------------------------------- | -------------------------------------------------------------------------------------------------- |
| LTV vs `LTV_MAX` and `MARKET_LLTV`      | Distance to the delever trigger and to liquidation.                                                |
| `rebalance()` calls emitting no event   | Price bound is skipping the swap — likely `maxSlippageBps` too tight or an oracle/pool divergence. |
| Yield/loan pool depth vs TVL            | Crash-day delever throughput ([`risk-disclosures.md` §11](./risk-disclosures.md)).                 |
| Morpho market utilization               | A fully-utilized market blocks deposits and lever-up.                                              |
| Oracle price vs pool price, both pairs  | Divergence both delays rebalancing and inflates the NAV mark.                                      |
| `EmergencyRecoveryScheduled`            | Holders' only warning that the 7-day exit window has started.                                      |
| `FeesAccrued` absent over a long window | `feeRecipient` unset or de-allowlisted, so accrual is silently skipping the mint.                  |
