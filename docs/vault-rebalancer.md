# Vault Rebalancer

**Status:** Draft
**Owner:** @Jordan Ribbink

A Cadence resource that pokes a single Solidity function on an interval via [`FlowTransactionScheduler`](https://github.com/onflow/flips/blob/main/protocol/20250609-scheduled-transactions.md) (FLIP 330).

## Assumptions

- **EVM-side errors don't panic the scheduled tx.** `coa.call` surfaces revert/OOG as a non-successful `EVM.Result`, never as a Cadence panic. The failure model rests on this — without it, an EVM revert would abort the scheduled tx before it can self-reschedule, killing the chain.
- **Off-chain tick liveness monitoring exists.** Several failure modes (scheduler unavailability, fee-vault depletion, COA depletion) are detectable only as missing events; operators must observe staleness and trigger recovery before LTV drifts to liquidation.

## What we require from the EVM contract

- **`rebalance()` is idempotent and self-guarding** — it inspects vault state and either acts or no-ops.
- **`rebalance()` is permissionless** — callable by any EOA.
- **The COA's EVM-side authority is narrow** — restricted to invoking `rebalance()` only (no admin or fund-movement entrypoints). This bounds the blast radius of an admin-compromised config rewrite to liveness impact.

## Design

One Cadence resource per EVM target, owned by an admin account. Stored at a deterministic path derived from the EVM target address.

- Holds a `Capability<auth(EVM.Call) &EVM.CadenceOwnedAccount>` — the EVM caller identity used to invoke `rebalance()`.
- Identity config (target address, calldata, scheduler priority) is immutable; changing any requires destroy + recreate. Tunable config (tick interval, EVM gas limit, execution effort) is mutable via an admin-entitlement-gated setter per field.
- On each tick: `coa.call(...)` against the EVM contract; emit one event for the EVM-side outcome; self-reschedule via `FlowTransactionScheduler.schedule(...)` with the current config.
- Self-rescheduling failures (insufficient FLOW, invalid capability) emit an event and halt the loop. The restart entry point is permissionless and idempotent — anyone can resume scheduling once the underlying condition is resolved.

**Scheduler priority.** The rebalancer uses Medium: it defers under slot contention but never rejects at submission (see *Scheduler availability* below).

**Effort and gas sizing.** EVM `gasLimit` bounds the EVM call's worst-case cost; the Cadence `executionEffort` budget is sized to cover that bound plus the self-reschedule tail, with margin skewed larger on the Cadence side. EVM out-of-gas just fails the EVM call (surfaced as a non-successful `EVM.Result`) and the next tick retries, but Cadence out-of-effort would abort the entire scheduled tx atomically — including the EVM call — stopping the chain. Values are calibrated from measured worst-case `rebalance()` cost and must be re-tuned if governance changes Cadence execution-effort weights. The self-reschedule tail also includes an internal slot search under Medium-priority contention whose effort consumption grows with distance to the next free slot; margin must accommodate this on top of the EVM call's worst-case cost (see *Scheduler availability*).

**Scheduler availability.** `FlowTransactionScheduler` is best-effort under slot contention — sustained contention can delay the next tick or temporarily halt the self-reschedule loop until manually restarted. Damage is bounded to liveness; the canonical recovery is direct (permissionless) `rebalance()` invocation on the EVM contract. Off-chain tick liveness monitoring is required.

## Failure modes and recovery

| Failure | Observable | Recovery |
| :--- | :--- | :--- |
| EVM call fails, transient (slippage, momentary state, out-of-gas) | Tick event with EVM error code | Next tick retries automatically; persistent OOG requires admin to raise the EVM gas limit |
| EVM call fails, sustained (role revoked EVM-side, persistent Solidity-side condition) | Tick event repeats with non-zero error code N ticks in a row | Admin addresses EVM-side condition (restore role, resolve Solidity state) |
| Fee vault depletion (Cadence scheduling fees) | Failure event with insufficient-FLOW reason; absence of subsequent scheduled events triggers alert | Admin tops up; signs tx to re-invoke self-reschedule |
| COA FLOW depletion (EVM-side gas) | Tick events repeat with non-zero EVM error code; off-chain balance script catches drift earlier | Anyone can send FLOW to the COA (permissionless, from either Cadence or EVM) |
| Cadence-side OOE (effort margin too tight) | Absence of expected events for the scheduled tx; rebalancer stops ticking | Admin re-invokes self-reschedule; retune effort margin if recurring |
| Sustained scheduler unavailability | Tick events absent or persistently delayed; tick liveness monitor alerts | Anyone invokes `rebalance()` directly on the EVM contract; permissionless restart resumes ticking once contention clears |

**Failure scope.** No single failure causes immediate solvency loss; failures degrade first to liveness. Prolonged outage can drift LTV and trigger Morpho liquidation under adverse prices, on a horizon set by market parameters and volatility — not by this design.

---

## Future scope

Possible evolutions of this design — none load-bearing for v0.2:

- **Config hardening.** Multisig/timelock on the setter entitlement, or pushing more fields toward immutability; fully-immutable redeploy-only may require self-replenishing funding to be practical.
- **Self-replenishing funding.** Fee top-ups sourced from a vault-level fee buffer or treasury sweep rather than admin out-of-band top-ups.

If business logic ever moves to Cadence, the failure model fundamentally changes. The principle worth preserving: split scheduling and business logic into separate scheduled transactions, so a panic in the work doesn't take down the rescheduling loop.
