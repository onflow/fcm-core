# Risk Disclosures

The protocol runs an automated, levered carry trade: it borrows against deposited collateral and redeploys the proceeds into a yield-bearing asset, continuously rebalancing to stay within a target health-factor band. Doing this requires the protocol to take actions — swaps, borrows, repayments — whose costs and risks are inherent to the strategy itself, not defects in its implementation.

This document enumerates those costs and risks: ways a holder's realized value can be _less than_ a naive pro-rata share of NAV, **by design**. Each one is a deliberate tradeoff (simplicity, gas, availability, fairness between holders), and the protocol does not protect against or compensate for it. None of the items below are security vulnerabilities.

Losses caused by a _malicious or byzantine dependency_ (Morpho, FlowSwap, oracles, tokens) are covered separately in [`security-surface.md`](./security-surface.md). This document is about costs and risks that exist even when every dependency behaves honestly.

## 1. Swap fees & price impact

To stay in the target health-factor band, the protocol must perform recurring swaps on public DEX pools. Every such swap pays the pool's fixed LP fee and is subject to price impact from the pool's current liquidity depth. This is an unavoidable, intended cost of running the strategy — not a security vulnerability — and it recurs on every deposit, redeem, and rebalance.

### 1.1 Deposit & redeem

As per the ERC4626 spec, `deposit` and `redeem` take no slippage-limit argument. Both route a leg of their flow through a DEX swap with no vault-enforced minimum output (see `SwapLib.swapExactIn` — deposit's borrow→yield leg and redeem's yield→loan leg set `amountOutMinimum = 0`). These functions are not intended to be called directly by end users, but through a router that adds its own slippage protection — e.g. the [ERC4626 Router](../README.md#erc4626-router). Calling `deposit`/`redeem` directly accepts whatever price the pool gives at execution time, bounded only by the pool's available liquidity.

### 1.2 Rebalance & harvest

`rebalance` and its internal `_harvest` leg bound their swaps to the oracle price discounted by `maxSlippageBps` (default 1%, admin-adjustable), so a single rebalance cannot pay more than that bound in price impact. Swap volume — and therefore total fee/impact cost — tracks how far the position has drifted from its target band, so an oscillating collateral price that repeatedly pushes the health factor across the band causes repeated lever/delever cycles and repeated swap costs. Any one rebalance's cost is bounded by `maxSlippageBps` plus the pool's fixed LP fee, but the number of rebalances — and therefore the aggregate cost over time — is unbounded and is a direct, intended consequence of following the market.

## 2. Performance fee crystallization on reversals

The performance fee crystallizes on unrealized, mark-to-market NAV gains above the all-time high-water mark — not on realized, locked-in profit. So a new peak can mint fee shares immediately, and if performance reverses afterward, that fee is **not refunded**. The high-water mark only ratchets up, so this can't be double-charged on the way back up, but a holder can still end up paying a fee on a gain that later evaporates.

## 3. Delayed compounding

When a rebalance or harvest swap partial-fills against its price-impact bound (§1.2), the position lands only part-way to its target instead of reverting. The remainder is picked up by a later `rebalance()` call. Until then:

- A partial delever leaves the health factor closer to the liquidation threshold for longer than a full delever would have.
- A partial harvest leaves surplus yield undeployed as collateral, and a partial lever-up leaves borrowing capacity idle — both foregone yield for the duration of the delay, not a realized loss.

This delay is inherent to choosing "best-effort partial fill" over "revert" as the rebalance semantics: it trades a hard failure for a soft, temporary drag that resolves over subsequent rebalances.

## 4. Oracle / NAV staleness

Deposit and redeem are unaffected by stale _yield_-oracle data: neither leg sizes itself off `yieldOracle` (the borrow-and-swap leg in `deposit` and the yield-sale leg in `redeem` both execute at whatever price the AMM gives at call time, and the collateral leg reads Morpho's own oracle fresh on every call). Only the harvest/delever legs of `rebalance` size themselves off `yieldOracle`, so only those are exposed to staleness in that price feed.

- `totalAssets()` is a stale read by default — callers needing an up-to-the-block NAV must accrue market interest in the same transaction first, which `deposit`, `redeem`, and `rebalance` all do internally. Reads outside these entry points (e.g. an off-chain integrator polling NAV) can be stale.
- The inner vault's own reported NAV may lag by days. Because the protocol sizes harvest and delever swaps off the yield oracle's price, a stale or lagging price can misjudge _when_ the harvest/delever band triggers, shifting realized value between "surplus captured as collateral" and "left as yield" without materially changing total NAV.

## 5. Leverage & liquidation

- The protocol runs a levered position by design (`healthFactorMin` / `healthFactorMax` band). If the health factor drifts below the liquidation threshold before a `rebalance()` call lands — e.g. a sharp adverse price move faster than the rebalance cadence, sustained rebalancer unavailability, or a manipulated/suppressed AMM spot price that blocks a needed delever — Morpho liquidates the position. Liquidation is a standard, external Morpho Blue mechanism, not a vault bug — but running leverage at all necessarily carries this risk, and the protocol's mitigations (health-factor band, rebalance cadence, off-chain liveness monitoring) are best-effort, not guarantees. A liquidation event forces losses onto all current holders proportionally, realized as reduced `totalAssets()`.
- The rebalancer's liveness is not guaranteed on-chain: scheduler
  contention, fee-vault depletion, or Cadence out-of-effort can silently stop the self-rescheduling loop. The permissionless direct `rebalance()` call is the backstop, but it depends on someone actually calling it before liquidation occurs.
- Liquidation is not an expected steady-state outcome — it is the tail case the health-factor band and rebalance cadence are meant to prevent. If it does occur, the path back to restoring collateral exposure (re-levering from scratch via `rebalance()`) is intentionally kept simple rather than optimized to minimize swap fees (e.g. via a flash-loan-based re-entry). Simplicity is chosen over cost-optimization for a path that should rarely, if ever, execute. On a realistic partial liquidation, one delever call restores the health-factor band at a swap cost well within a 2% NAV budget on top of the liquidation's own (already-realized) loss — the recovery path does not compound the damage.

## 6. Rounding

Every pro-rata computation in the vault (deposit share mint, redeem unwind slice sizing, fee-share mint) explicitly rounds in the vault's favor — i.e. against the individual caller and toward remaining/other holders:

- `deposit`: shares round down.
- `redeem` / `redeemInKind`: yield/debt/collateral pro-rata slices round down.
- Fee minting: rounds fee shares up, favoring the fee recipient over the diluted holders by a rounding unit.

Each individual rounding is dust-scale, but it is a real, permanent, one-way transfer of value away from the acting party on every interaction, compounding over the vault's lifetime and total call volume.

## 7. Virtual shares / decimals offset (inflation-attack mitigation)

A fixed decimals offset seeds the share/asset conversion with virtual shares — OpenZeppelin's standard ERC4626 mitigation. This is a deliberate, tiny, permanent dilution baked into every share-price computation, in exchange for making the classic first-depositor inflation attack economically infeasible.

## 8. TVL cap is a soft, not hard, bound

`maxTvl` blocks _new_ deposits once exceeded, but explicitly does not:

- prevent existing holdings from growing past `maxTvl` through market appreciation, or
- unwind the vault back under `maxTvl` if the admin lowers it below the current `totalAssets()`.

This is not a loss vector by itself, but it means `maxTvl` cannot be relied on as a hard cap on position size or AMM-liquidity exposure once a position already exists — relevant because swap price impact (§1) scales with position size, which `maxTvl` only imperfectly bounds.

## 9. Availability: freezes and blocked flows

These do not destroy principal, but can delay or temporarily block a holder's access to it, or the protocol's ability to act:

- **Emergency recovery timelock.** Once a recovery is scheduled, deposits freeze immediately; `redeem`/`redeemInKind` remain open during the timelock window, but lever-up is suppressed while a recovery is pending (delever still runs) — the position is deliberately not re-levered while wind-down is pending, foregoing yield for the duration of the timelock.
- **Underwater guard.** `deposit` reverts when the vault's gross position
  value is at or below its debt while shares are outstanding. This correctly prevents minting shares against a zero or negative NAV, but also means holders cannot deposit their way out of an underwater position — it must recover, be liquidated, or go through emergency recovery before deposits resume.
- **Allowlist (`EARLY_ACCESS_ROLE`).** Transfers and mints require both
  parties to hold the role; a holder who is later de-allowlisted can still redeem/redeemInKind but cannot transfer shares to another address. Principal is not lost, but liquidity/optionality is restricted by design.
- **A fully utilized Morpho market blocks deposits** — the vault has no supply-only fallback if the market cannot absorb the borrow leg. The same condition also blocks `rebalance`'s lever-up leg; because the whole call is one transaction, that revert unwinds any harvest work that already ran earlier in the same `rebalance()` call.
- **Morpho's own health checks can block `redeem()`** when the position is already unhealthy (health factor below the liquidation threshold at execution time). The recommended recovery for a caller hitting this is to invoke `rebalance()` first to restore health, then retry the redeem.

## 10. Admin-adjustable parameters have no timelock

Unlike emergency recovery (which is gated behind `recoveryDelay`), the owner's other configuration levers take effect immediately, with no delay and no on-chain veto window for holders:

- `setMaxSlippageBps` — can widen the rebalance/harvest price-impact bound up to 100% (effectively removing it) with immediate effect on the next rebalance.
- `setManagementFeeBps` / `setPerformanceFeeBps` / `setFeeRecipient` — take effect immediately after accruing at the old rate; there is no cooldown between a rate change and it applying to subsequent accrual.
- `setMaxTvl` — can be raised or lowered instantly.
- Role administration (`grantRole` / `revokeRole` for `EARLY_ACCESS_ROLE`) and `transferOwnership` (two-step, but no time delay between steps) take effect as soon as the transactions land.

This is an accepted trust assumption in the admin/owner key, not a contract defect: holders are trusting the admin to act in good faith and there is no on-chain mechanism forcing advance notice of a parameter change. Operational mitigations (multisig, monitoring, off-chain governance process) are outside the scope of the contract itself.

## References

- [`architecture.md`](./architecture.md) — deposit/withdrawal flows, sandwich-attack mitigation
- [`security-surface.md`](./security-surface.md) — dependency/byzantine failure modes
- [`vault-rebalancer.md`](./vault-rebalancer.md) — rebalancer liveness and recovery
- [`FCMVault.sol`](../solidity/src/FCMVault.sol), [`MarketLib.sol`](../solidity/src/libraries/MarketLib.sol), [`SwapLib.sol`](../solidity/src/libraries/SwapLib.sol)
