# Vault Rebalancer

**Status:** Draft
**Owner:** @Jordan Ribbink

A Cadence resource that pokes a single Solidity function on an interval via [`FlowTransactionScheduler`](https://github.com/onflow/flips/blob/main/protocol/20250609-scheduled-transactions.md) (FLIP 330).

## What we require from the EVM contract

- **`rebalance()` is idempotent and self-guarding** — it inspects vault state and either acts or no-ops.
- **Internal errors revert the EVM transaction cleanly.** `coa.call` surfaces them as `EVM.Result`, not a Cadence panic.
- **The COA's EVM-side authority is narrow** — restricted to invoking `rebalance()` only (no admin or fund-movement entrypoints). This bounds the blast radius of an admin-compromised Config rewrite to liveness impact.
- **Solvency does not depend on the rebalancer firing.** Insolvency-critical actions take permissionless paths: emergency deleverage triggers above a hard-LTV ceiling, and liquidations are Morpho-driven and external. If a future change makes solvency depend on tick liveness, the Medium-priority choice must be revisited.

## Design

One Cadence resource, owned by an admin account.

- Holds a `Capability<auth(EVM.Call) &EVM.CadenceOwnedAccount>` — the EVM caller identity used to invoke `rebalance()`.
- Holds a `Config` value: target EVM address, calldata, EVM gas limit, scheduler priority, scheduled-tx execution effort, tick interval. Mutable via an admin-entitlement-gated `Configure` setter that replaces the whole Config.
- On each tick: `coa.call(...)` against the EVM contract; emit one event for the EVM-side outcome; self-reschedule via `FlowTransactionScheduler.schedule(...)` with the same parameters.
- Self-rescheduling failures (insufficient FLOW, invalid capability) emit an event and halt the loop. The restart entry point is permissionless and idempotent — anyone can resume scheduling once the underlying condition is resolved.

**Scheduler priority.** The rebalancer uses Medium: it defers under slot contention but never rejects at submission. The tick interval is sized to absorb worst-case deferral.

**Effort and gas sizing.** EVM `gasLimit` bounds the EVM call's worst-case cost; the Cadence `executionEffort` budget is sized to cover that bound plus the self-reschedule tail, with margin skewed larger on the Cadence side. EVM out-of-gas just fails the EVM call (surfaced as a non-successful `EVM.Result`) and the next tick retries, but Cadence out-of-effort would abort the entire scheduled tx atomically — including the EVM call — stopping the chain. Values are calibrated from measured worst-case `rebalance()` cost and must be re-tuned if governance changes Cadence execution-effort weights.

## Failure modes and recovery

| Failure | Observable | Recovery |
| :--- | :--- | :--- |
| EVM call fails, transient (slippage, momentary state, out-of-gas) | Event with EVM error code | Next tick retries automatically; persistent OOG requires admin to raise EVM `gasLimit` via `Configure` |
| EVM call fails, sustained (role revoked EVM-side, persistent Solidity-side condition) | Event repeats N ticks in a row | Admin addresses EVM-side condition (restore role, resolve Solidity state) |
| Fee vault depletion (Cadence scheduling fees) | Per-tick fee-balance in event; absence of scheduled events triggers alert | Admin tops up; signs tx to re-invoke self-reschedule |
| COA FLOW depletion (EVM-side gas) | Per-tick COA balance in event; EVM calls fail with insufficient-balance error | Admin tops up the COA |
| Cadence-side OOE (effort margin too tight) | Absence of expected events for the scheduled tx; rebalancer stops ticking | Admin re-invokes self-reschedule; retune effort margin if recurring |

All failures are liveness-only (no solvency impact). Off-chain monitoring of tick freshness, per-tick EVM result status, fee-vault balance, and COA balance is required for reliable operation.

---

## Future scope

Possible evolutions of this design — none load-bearing for v0.2:

- **Config hardening.** Multisig/timelock on the `Configure` entitlement, or partial-to-full immutability of Config; fully-immutable redeploy-only may require self-replenishing funding to be practical.
- **Self-replenishing funding.** Fee top-ups sourced from a vault-level fee buffer or treasury sweep rather than admin out-of-band top-ups.
- **Off-chain keeper backup.** A second caller of `rebalance()`.

If business logic ever moves to Cadence, the failure model fundamentally changes. The principle worth preserving: split scheduling and business logic into separate scheduled transactions, so a panic in the work doesn't take down the rescheduling loop.
