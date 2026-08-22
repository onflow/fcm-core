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

## 4. Oracle / NAV staleness and liveness

### 4.1 Liveness — both oracles must be live for any exit

This is a property of the levered position itself, not something the vault layers on top:

- **Market oracle.** Morpho reads `marketParams.oracle` inside its own health check on every `withdrawCollateral` made against an outstanding borrow. `_isHealthy` short-circuits before the oracle read only when `borrowShares == 0`, and because a redemption repays just its pro-rata slice — and the virtual-share offset keeps `claims > shares` — the position never gets there. **No exit that moves collateral can be market-oracle-free, whatever the vault does.** `redeem` and `redeemInKind` both inherit that from Morpho.
- **Yield oracle.** `YieldTokenOracle` is a thin wrapper we implement over the inner vault: `price()` is `convertToAssets(CONVERSION_SAMPLE)` rescaled to 1e36, with a non-zero sample enforced at construction. There is no feed, no heartbeat, and nothing that can go stale or fail independently of the inner vault. It reverts only if the inner ERC4626's `convertToAssets` reverts — which ERC4626 requires it not to do, and an inner vault broken badly enough to fail that read has already made the yield leg both unvaluable and unsellable.

So an oracle outage blocks withdrawals rather than mispricing them, and for the market oracle that is Morpho's behaviour rather than a vault choice. Emergency recovery is the one path that reads no oracle at all.

One narrow case does remain open: if the inner vault breaks while the market oracle is healthy, `redeemInKind` is blocked only by the fee accrual that runs on entry — its own slice math is pure `shares/claims`, and Morpho's health check needs just the market oracle. That is the scenario an in-kind hatch is most wanted for.

### 4.2 Staleness

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
- **Allowlist (`earlyAccess`).** Transfers and mints require both
  parties to be allowlisted; a holder who is later de-allowlisted can still redeem/redeemInKind but cannot transfer shares to another address. Principal is not lost, but liquidity/optionality is restricted by design.
- **A fully utilized Morpho market blocks deposits** — the vault has no supply-only fallback if the market cannot absorb the borrow leg. The same condition also blocks `rebalance`'s lever-up leg; because the whole call is one transaction, that revert unwinds any harvest work that already ran earlier in the same `rebalance()` call.
- **Morpho's own health checks can block `redeem()`** when the position is already unhealthy (health factor below the liquidation threshold at execution time). The recommended recovery for a caller hitting this is to invoke `rebalance()` first to restore health, then retry the redeem.
- **An unavailable oracle blocks every exit**, including the in-kind escape hatch — see [§4.1](#41-liveness--both-oracles-must-be-live-for-any-exit). For the market oracle this is Morpho's own requirement for withdrawing collateral against a borrow, so it is unavoidable for any exit that moves collateral.

## 10. Admin-adjustable parameters have no timelock

Unlike emergency recovery (which is gated behind `recoveryDelay`), the owner's other configuration levers take effect immediately, with no delay and no on-chain veto window for holders:

- `setMaxSlippageBps` — can widen the rebalance/harvest price-impact bound up to its 10% hard cap with immediate effect on the next rebalance.
- `setManagementFeeBps` / `setPerformanceFeeBps` / `setFeeRecipient` — take effect immediately after accruing at the old rate; there is no cooldown between a rate change and it applying to subsequent accrual.
- `setMaxTvl` — can be raised or lowered instantly.
- Allowlist administration (`grantEarlyAccess` / `revokeEarlyAccess`) and `transferOwnership` (two-step, but no time delay between steps) take effect as soon as the transactions land.
- `renounceOwnership` is a one-way exit that permanently disables every lever above, emergency recovery included; the vault keeps operating for existing allowlisted holders but can never be reconfigured or wound down.

This is an accepted trust assumption in the admin/owner key, not a contract defect: holders are trusting the admin to act in good faith and there is no on-chain mechanism forcing advance notice of a parameter change. Operational mitigations (multisig, monitoring, off-chain governance process) are outside the scope of the contract itself.

## 11. Factory deployment is not an endorsement

`FCMVaultFactory.createVault` is permissionless. Anyone can deploy an `FCMVault` through the canonical factory with any parameters they like, and the resulting vault will have a legitimate-looking provenance: correct bytecode, deterministic address, `VaultCreated` event from the official factory.

None of that says the vault is safe to deposit into. The factory does not vet the parameters, and the constructor only checks what it can decide locally — it cannot verify that the yield oracle prices the right pair, that the configured pools match the tokens and fee tiers the router will use, or who holds the owner key. **Verify a specific vault's configuration before depositing; do not treat "deployed by the factory" as a signal.** In particular the `owner` is set from deploy-time parameters, so a factory-deployed vault can be owned by anyone — with all the powers in §10, including the emergency-recovery sweep.

The design bar is that a misconfigured vault is *unusable* rather than quietly wrong: a wrong market tuple reverts on the first Morpho call, a wrong yield oracle reverts on first use, and a mismatched pool degrades rebalancing rather than removing the price bound (see [`architecture.md`](./architecture.md#deployment-trust-model--constructor-validation)). That bounds accidents. It does not protect against a vault configured adversarially on purpose, which is a matter of checking before you deposit.

## References

- [`architecture.md`](./architecture.md) — deposit/withdrawal flows, sandwich-attack mitigation
- [`security-surface.md`](./security-surface.md) — dependency/byzantine failure modes
- [`vault-rebalancer.md`](./vault-rebalancer.md) — rebalancer liveness and recovery
- [`FCMVault.sol`](../solidity/src/FCMVault.sol), [`MorphoLib.sol`](../solidity/src/libraries/MorphoLib.sol), [`SwapLib.sol`](../solidity/src/libraries/SwapLib.sol)
