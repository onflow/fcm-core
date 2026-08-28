# Risk Disclosures

This document enumerates costs and risks that can result in a reduced or negative yield. Most are deliberate tradeoffs (simplicity, gas, availability, fairness between holders) that the protocol does not protect against or compensate for; none of the items below are security vulnerabilities.

Losses caused by a dependency (Morpho, FlowSwap, oracles, tokens) being unavailable or malicious are covered separately in [`security-surface.md`](./security-surface.md). This document is about costs and risks that exist even when every dependency behaves honestly.

## 1. Swap fees & price impact

To stay in the target health-factor band, the protocol must perform recurring swaps on public DEX pools. Every such swap pays the pool's fixed LP fee and is subject to price impact from the pool's current liquidity depth. This is an unavoidable, intended cost of running the strategy - it recurs on every deposit, redeem, rebalance and harvest.

### 1.1 Deposit & redeem

As per the ERC4626 spec, `deposit` and `redeem` take no slippage-limit argument. Both route a leg of their flow through a DEX swap with no vault-enforced minimum output. These functions are not intended to be called directly by end users, but through a router that adds its own slippage protection. Calling `deposit`/`redeem` directly accepts whatever price the pool gives at execution time, bounded only by the pool's available liquidity.

### 1.2 Rebalance & harvest

`rebalance` and its internal `_harvest` leg bound their swaps to the oracle price discounted by `maxSlippageBps` (owner-adjustable, max 10%), so a single rebalance cannot pay more than that bound in price impact. Swap volume — and therefore total fee/impact cost — tracks how far the position has drifted from its target band, so an oscillating collateral price that repeatedly pushes the health factor across the band causes repeated lever/delever cycles and repeated swap costs. Any one rebalance's cost is bounded by `maxSlippageBps` plus the pool's fixed LP fee, but the number of rebalances — and therefore the aggregate cost over time — is unbounded and is a direct, intended consequence of following the market.

## 2. Performance fee crystallization on reversals

The performance fee crystallizes on unrealized, mark-to-market NAV gains above the all-time high-water mark — not on realized, locked-in profit. So a new peak can mint fee shares immediately, and if performance reverses afterward, that fee is **not refunded**. The high-water mark only ratchets up, so this can't be double-charged on the way back up, but a holder can still end up paying a fee on a gain that later evaporates.

## 3. Delayed compounding

`rebalance()` and `harvest()` are not instant, there is a delay between the position drifting out of band and a call actually landing. The swap is bounded to the oracle price by `maxSlippageBps` (§1.2): if the pool price has moved too far from the oracle, the call partial-fills or no-ops rather than completing.

- A late delever leaves the health factor closer to the liquidation threshold for longer than a full delever would have.
- A late harvest leaves surplus yield undeployed as collateral, and a partial lever-up leaves borrowing capacity idle — both foregone yield for the duration of the delay.

## 4. Oracle staleness

A stale market oracle delays `rebalance()`: the position's health factor is computed from that price, and a stale reading understates the true drift, permitting a larger, unrecognized price swing to accumulate before the position is brought back within band. A stale yield oracle has the analogous effect on `harvest()`, delaying recognition of harvestable surplus. In either case, a large enough divergence between the oracle price and the pool's actual price can also prevent the swap from executing at all, rather than merely delaying it.

## 5. Leverage & liquidation

The vault runs a levered position by design. Several mitigations reduce the risk of liquidation, but cannot eliminate it - how likely a liquidation is depends on how aggressive the deployed LTV targets are. If the health factor crosses the liquidation line before a `rebalance()` lands, Morpho's liquidators seize collateral and the loss is realized pro-rata across all holders as a permanent reduction in `totalAssets()`. It does not reverse when the price recovers.

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
- unwind the vault back under `maxTvl` if the owner lowers it below the current `totalAssets()`.

This is not a loss vector by itself, but it means `maxTvl` cannot be relied on as a hard cap on position size or AMM-liquidity exposure once a position already exists.

## 9. Availability: freezes and blocked flows

These do not destroy principal, but can delay or temporarily block a holder's access to it, or the protocol's ability to act:

- **Emergency recovery timelock.** Once a recovery is scheduled, deposits freeze immediately; `redeem`/`redeemInKind` remain open during the timelock window, but lever-up is suppressed while a recovery is pending (delever still runs) — the position is deliberately not re-levered while wind-down is pending, foregoing yield for the duration of the timelock.
- **Underwater guard.** `deposit` reverts when the vault's gross position
  value is at or below its debt while shares are outstanding. This prevents minting shares against a zero or negative NAV.
- **Allowlist (`earlyAccess`).** Transfers and mints require both
  parties to be allowlisted; a holder who is later de-allowlisted can still redeem/redeemInKind but cannot transfer shares to another address. Principal is not lost, but liquidity/optionality is restricted by design.
- **A fully utilized Morpho market blocks deposits** — the vault has no supply-only fallback if the market cannot absorb the borrow leg, `deposit` will revert.
- **`redeem()` reverts (`VaultUnhealthy`) whenever the health factor is below `healthFactorMin`** — outside the rebalance band, not just when actually unhealthy — so exits don't compete with the rebalancer for the same pool liquidity. A permissionless `rebalance()` call restores the band and unblocks it; `redeemInKind` carries no such gate.
- **A large `redeem` may need splitting.** If the yield sale falls short of the debt slice, `redeem` flash-loans collateral, drawing the Morpho singleton twice before repaying once — capping one call at ~50% of the position where this vault dominates the market. Larger exits must be split, or routed through `redeemInKind`, which never flashes.
- **`redeemInKind` preserves the health factor rather than improving it**, so Morpho still rejects it below HF = 1 — it's swap-free, but not an exit of last resort.

## 10. Owner-adjustable parameters have no timelock

Unlike emergency recovery (which is gated behind `recoveryDelay`), the owner's other configuration levers take effect immediately, with no delay and no on-chain veto window for holders:

- `setMaxSlippageBps` — can widen the rebalance/harvest price-impact bound up to its 10% hard cap with immediate effect on the next rebalance.
- `setManagementFeeBps` / `setPerformanceFeeBps` / `setFeeRecipient` — take effect immediately after accruing at the old rate; there is no cooldown between a rate change and it applying to subsequent accrual.
- `setMaxTvl` — can be raised or lowered instantly.
- Allowlist administration (`grantEarlyAccess` / `revokeEarlyAccess`) and `transferOwnership` (two-step, but no time delay between steps) take effect as soon as the transactions land.

This is an accepted trust assumption in the owner key, not a contract defect: holders are trusting the owner to act in good faith and there is no on-chain mechanism forcing advance notice of a parameter change. Operational mitigations (multisig, monitoring, off-chain governance process) are outside the scope of the contract itself.

## 11. External liquidity dependencies

The vault creates none of the liquidity it depends on and cannot compel anyone to provide it:

- **Loan liquidity in the Morpho market.** A fully-utilized market blocks deposits and `rebalance`'s lever-up leg (§9); supplied by third-party lenders with no guarantee they stay.
- **Yield/debt pool depth.** Backs every rebalance and standard `redeem`. Sized for ~2–3% of protocol TVL; the binding constraint is crash-day throughput, not steady-state cost — if arbitrage restocking stalls mid-crash, the delever takes longer than the pool's depth suggests, compounding into §5.
- **Collateral/debt pool depth.** Used only by `harvest` and `redeem`'s shortfall path. A partial fill here degrades compounding rather than safety (§3), except inside `redeem`, where it reduces the redeemer's payout.
- **Redemption capacity inside the yield source.** Backs the AMM price rather than the vault's own flows directly; if the yield source can't honour redemptions, the yield leg can trade at an arbitrary discount (§13).

None of this is inside the protocol's control, and all four are correlated: what thins a pool also spikes borrow utilization and stresses the yield source.

## 12. The carry spread can go to zero or negative

The strategy earns `(yield rate − borrow rate) × deployed fraction`, minus rebalance cost and fees, and neither rate is controlled by the vault. The borrow rate is the swing variable: it rises with utilization, so it climbs exactly when the vault is most likely to be levering up, and has historically spiked to roughly double its normal level in stress — compressing the spread toward zero while leverage, liquidation risk, and rebalance costs stay exactly where they were. The yield rate can also fall independently, with no floor and no hedge.
