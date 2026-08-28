# Risk Disclosures

Costs and risks that can result in a reduced or negative yield. Most are deliberate tradeoffs — simplicity, gas, availability, fairness between holders — that the protocol does not protect against or compensate for. **None of the items below are security vulnerabilities.**

This document is about costs that exist even when every dependency behaves honestly. Losses caused by a dependency being unavailable are in [`security-surface.md`](./security-surface.md); adversarial scenarios are in [`security.md`](./security.md).

## 1. Swap fees and price impact

To stay in the target LTV band, the protocol must perform recurring swaps on public DEX pools. Every such swap pays the pool's fixed LP fee and is subject to price impact from the pool's current liquidity depth. This is an unavoidable, intended cost of running the strategy — it recurs on every deposit, redeem, rebalance and harvest.

### 1.1 Deposit and redeem

The ERC-4626 signatures `deposit(assets, receiver)` and `redeem(shares, receiver, owner)` take no slippage-limit argument, and both route a leg of their flow through a DEX swap with no vault-enforced minimum output. Calling them directly accepts whatever price the pool gives at execution time, bounded only by the pool's available liquidity.

The vault ships slippage-protected overloads — `deposit(assets, receiver, minSharesOut)` and `redeem(shares, receiver, owner, minAssetsOut)` — which revert `SlippageExceeded` on a shortfall. **Use those, or a router that enforces an equivalent bound.** Note that even with a bound, the cost is still paid; the bound only caps how bad it is allowed to get before the transaction reverts.

Entry and exit costs are borne by the acting party, not socialized: shares are minted against the _realized_ NAV delta a deposit produced, so the depositor's own fee and price impact come out of their own share count.

### 1.2 Rebalance and harvest

`rebalance` and `harvest` bound their swaps to the oracle price discounted by `maxSlippageBps` (owner-adjustable, hard cap 10%), so a single call cannot pay more than that bound in price impact.

Swap volume — and therefore total fee/impact cost — tracks how far the position has drifted from its band, so an oscillating collateral price that repeatedly pushes LTV across the band causes repeated lever/delever cycles and repeated swap costs. Any one rebalance's cost is bounded by `maxSlippageBps` plus the pool's fixed LP fee, but the _number_ of rebalances — and therefore the aggregate cost over time — is unbounded and is a direct, intended consequence of following the market.

## 2. Performance fee crystallization on reversals

The performance fee crystallizes on unrealized, mark-to-market NAV gains above the all-time high-water mark — not on realized, locked-in profit. A new peak can mint fee shares immediately, and if performance reverses afterward, that fee is **not refunded**.

The high-water mark only ratchets up, so the same gain cannot be charged twice on the way back up, but a holder can still end up paying a fee on a gain that later evaporates.

## 3. Delayed compounding

`rebalance()` and `harvest()` are not instant; there is a delay between the position drifting out of band and a call actually landing. The swap is bounded to the oracle price by `maxSlippageBps` (§1.2): if the pool price has moved too far from the oracle, the call partial-fills or no-ops rather than completing.

- A late delever leaves LTV closer to the liquidation threshold for longer than a full delever would.
- A late harvest leaves surplus yield undeployed as collateral, and a partial lever-up leaves borrowing capacity idle — both foregone yield for the duration of the delay.

## 4. Oracle staleness and mark-vs-exit divergence

A stale market oracle delays `rebalance()`: the position's LTV is computed from that price, and a stale reading understates the true drift, permitting a larger, unrecognized price swing to accumulate before the position is brought back within band. A stale yield oracle has the analogous effect on `harvest()`, delaying recognition of harvestable surplus. In either case, a large enough divergence between the oracle price and the pool's actual price can prevent the swap from executing at all rather than merely delaying it.

Separately and more importantly: the yield leg is **marked at the yield vault's redemption rate but can only be exited through the AMM**. When the pool trades the yield share below its redemption rate, `totalAssets()` — and therefore quoted share price — exceeds what the position could actually realize. A redemption at that moment realizes the pool price, not the mark.

## 5. Leverage and liquidation

The vault runs a levered position by design. Several mitigations reduce the risk of liquidation but cannot eliminate it; how likely a liquidation is depends on how aggressive the deployed LTV band is relative to the market's LLTV.

If LTV crosses the liquidation line before a `rebalance()` lands, Morpho's liquidators seize collateral and the loss is realized pro-rata across all holders as a permanent reduction in `totalAssets()`. It does not reverse when the price recovers.

## 6. Rounding

Every pro-rata computation in the vault rounds in the vault's favor — i.e. against the individual caller and toward remaining holders:

- `deposit`: shares round down.
- `redeem` / `redeemInKind`: yield/collateral pro-rata slices round down; the debt slice rounds up.
- Fee minting: fee shares round up, favoring the fee recipient over the diluted holders by a rounding unit.
- `totalAssets()`: the yield leg is valued down and the debt marked up, so NAV is conservative.

Each individual rounding is dust-scale, but it is a real, permanent, one-way transfer of value away from the acting party on every interaction, compounding over the vault's lifetime and total call volume.

## 7. Virtual shares / decimals offset (inflation-attack mitigation)

A fixed decimals offset of 6 seeds the share/asset conversion with virtual shares — OpenZeppelin's standard ERC-4626 mitigation, reimplemented here rather than inherited (the vault extends `ERC20` directly). This is a deliberate, tiny, permanent dilution baked into every share-price computation, in exchange for making the classic first-depositor inflation attack economically infeasible.

A related integration note: `decimals()` reports `collateralDecimals + 6`, so the offset is absorbed by the reported scale and one whole share is worth roughly one whole asset at inception. Integrators should format share balances with `decimals()` and convert with `convertToAssets`; they must not assume share decimals equal the collateral's.

## 8. TVL cap is a soft, not hard, bound

`maxTvl` blocks _new_ deposits once exceeded, but explicitly does not:

- prevent existing holdings from growing past `maxTvl` through market appreciation, or
- unwind the vault back under `maxTvl` if the owner lowers it below the current `totalAssets()`.

This is not a loss vector by itself, but it means `maxTvl` cannot be relied on as a hard cap on position size or AMM-liquidity exposure once a position already exists.

## 9. Availability: freezes and blocked flows

These do not destroy principal, but can delay or temporarily block a holder's access to it, or the protocol's ability to act.

- **Pending emergency recovery.** Once scheduled, `deposit` and `harvest` revert immediately, and `rebalance`'s lever-up branch is suppressed (delever still runs) — the position is deliberately not re-levered while wind-down is pending, foregoing yield for the duration of the timelock. `redeem` and `redeemInKind` stay open for the full 7-day window. The owner may cancel, restoring everything.
- **Executed emergency recovery is terminal.** This one _is_ a principal risk rather than a delay, and is tracked here only because it starts as an availability freeze. After execution, `redeem`, `redeemInKind`, and `rebalance` revert permanently, and the entire position has been swept to the owner. See [`security.md` § Owner trust](./security.md#owner-trust).
- **Underwater guard.** `deposit` reverts when the vault's NAV is zero while shares are outstanding, preventing shares being minted against a zero or negative NAV.
- **Allowlist (`earlyAccess`).** Mints require the receiver to be allowlisted and transfers require both parties to be; a holder who is later de-allowlisted can still `redeem`/`redeemInKind` — burns are unconditionally permitted — but cannot transfer shares. Principal is not lost, but liquidity and optionality are restricted by design.
- **A fully utilized Morpho market blocks deposits.** The vault has no supply-only fallback if the market cannot absorb the borrow leg, so `deposit` reverts.
- **`redeem()` reverts `VaultUnhealthy` whenever LTV exceeds `LTV_MAX` and the vault still holds yield** — that is, anywhere above the rebalance band, not only when the position is genuinely near liquidation. This is intentional, so exits do not compete with the rebalancer for the same pool liquidity. A permissionless `rebalance()` call restores the band and unblocks it; `redeemInKind` carries no such gate.
- **`redeemInKind` preserves LTV rather than improving it**, so Morpho still rejects it on an underwater position. It is swap-free, but not an exit of last resort.
- **`harvest` can revert on a thin collateral/loan pool.** If leg 2 cannot convert all the loan tokens raised by leg 1, the call reverts `LeftoverLoanTokens`. Retrying with a smaller `maximumYield` succeeds; compounding is delayed, nothing is lost.

## 10. Owner-adjustable parameters have no timelock

Unlike emergency recovery (gated behind a 7-day delay), the owner's configuration levers take effect immediately, with no delay and no on-chain veto window for holders:

- `setMaxSlippageBps` — can widen the rebalance/harvest price-impact bound up to its 10% hard cap, effective on the next rebalance.
- `setManagementFeeBps` / `setPerformanceFeeBps` / `setFeeRecipient` — take effect immediately after accruing at the old rate; there is no cooldown between a rate change and it applying to subsequent accrual. Rates are hard-capped at 10 %/yr and 50 % respectively.
- `setMaxTvl` — can be raised or lowered instantly.
- Allowlist administration (`grantEarlyAccess` / `revokeEarlyAccess`) and `transferOwnership` (two-step, but with no time delay between steps) take effect as soon as the transactions land.

This is an accepted trust assumption in the owner key, not a contract defect: holders are trusting the owner to act in good faith, and there is no on-chain mechanism forcing advance notice of a parameter change. Operational mitigations (multisig, monitoring, off-chain governance process) are outside the scope of the contract itself.

## 11. External liquidity dependencies

The vault creates none of the liquidity it depends on and cannot compel anyone to provide it:

- **Loan liquidity in the Morpho market.** A fully-utilized market blocks deposits and `rebalance`'s lever-up leg (§9); it is supplied by third-party lenders with no guarantee they stay.
- **Yield/loan pool depth.** Backs every rebalance and standard `redeem`. The binding constraint is crash-day throughput, not steady-state cost — if arbitrage restocking stalls mid-crash, the delever takes longer than the pool's depth suggests, compounding into §5. Whether a given pool is deep enough is a property of the deployment, not of the contract.
- **Collateral/loan pool depth.** Used only by `harvest` and `redeem`'s reconciliation leg. A partial fill here degrades compounding rather than safety (§3), except inside `redeem`, where it reduces the redeemer's payout.
- **Redemption capacity inside the yield source.** Backs the AMM price rather than the vault's own flows directly; if the yield source cannot honour redemptions, the yield leg can trade at an arbitrary discount to the mark (§4).

None of this is inside the protocol's control, and all four are correlated: what thins a pool also spikes borrow utilization and stresses the yield source.

## 12. The carry spread can go to zero or negative

The strategy earns `(yield rate − borrow rate) × deployed fraction`, minus rebalance cost and fees, and neither rate is controlled by the vault.

The borrow rate is the swing variable: it is set by the market's IRM and rises with utilization, so it climbs exactly when the vault is most likely to be levering up. A sustained spike compresses the spread toward zero — or through it — while leverage, liquidation risk, and rebalance costs stay exactly where they were. How far it can climb is a property of the specific market's IRM and its supply base, not of this contract. The yield rate can also fall independently, with no floor and no hedge.
