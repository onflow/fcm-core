# FCM Security Model

Adversarial analysis: what an attacker (or a careless deployer) could try, and what stops it.

This is one of four security-adjacent documents, split by the kind of question they answer:

| Document                                          | Question                                                        |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| this file                                         | What can an adversary do, and what bounds it?                    |
| [`security-surface.md`](./security-surface.md)    | What still works when a dependency goes down?                    |
| [`risk-disclosures.md`](./risk-disclosures.md)    | What does it cost when *nothing* goes wrong?                     |
| [`architecture.md`](./architecture.md)            | How does it work, and why is it built that way?                  |

## Deployment trust model and constructor validation

`FCMVaultFactory.createVault` is permissionless: anyone can deploy an `FCMVault` with any `InitParams`. **Deployment through the canonical factory is not an endorsement.** The factory fixes the bytecode and makes the address deterministic via CREATE2; it says nothing about whether the parameters describe a sane vault. A vault must be judged on its own configuration — tokens, Morpho market, pools, oracles, owner — exactly as any directly deployed contract would be.

### What the constructor checks

Only what is cheap and locally decidable:

- the LTV band ordering, `ltvMin < ltvMax < marketLltv`;
- a non-zero address for every external dependency, and a non-zero `marketLltv`;
- **implicitly**, that both pool addresses are contracts exposing `fee()` — the constructor reads and stores each pool's fee tier, so a non-contract or non-pool address reverts at deploy time;
- **implicitly**, that `collateralToken` and `loanToken` are contracts — the `forceApprove` calls to Morpho revert against an address with no code.

Note that `forceApprove` validates the *token*, not the spender: a `morpho` address that is a non-contract passes the constructor and fails later, on the first Morpho call.

### What it deliberately does not check

A constructor cannot perform a full correctness check. Whether the yield oracle really prices the yield token in loan tokens, whether the configured pool is the pool the vault will actually trade through, whether the yield source is solvent — these are properties of external contracts and of live state, not of the arguments. A partial on-chain check would mostly buy false confidence.

The bar held instead: **a misconfigured vault must be unusable, never quietly wrong.** A vault that reverts on every deposit is an acceptable outcome of a fat-fingered deployment; one that accepts deposits while silently mispricing them is not. Two structural properties do most of that work:

- **Morpho validates the market tuple.** The market id is `keccak256(loanToken, collateralToken, marketOracle, marketIrm, marketLltv)`, and every Morpho entry point requires `market[id].lastUpdate != 0`. Get any one of those five wrong and the derived id points at a market that was never created, so `supplyCollateral`, `borrow`, `repay`, and `withdrawCollateral` all revert. The vault is dead on arrival rather than quietly operating against the wrong market.
- **The swap price bound is oracle-derived, not pool-derived.** `SwapLib.swapLimit` builds `sqrtPriceLimitX96` from the oracle rate discounted by `maxSlippageBps`; the configured pool address is read only for the `slot0` spot check that decides whether to attempt the swap at all, and the pool then enforces the limit natively. So a mismatched pool corrupts the go/skip decision — spurious skips leaving `rebalance` a no-op, or attempts the pool rejects — but it cannot make a swap execute outside the oracle-derived bound.

What is left unvalidated therefore lands in "unusable" rather than "exploitable": a wrong or zero `yieldOracle` reverts the first time `price()` is decoded, a wrong market tuple reverts on the first Morpho call, and a wrong pool degrades rebalancing instead of unbounding it.

One caveat on "dead on arrival": the vault is inert *by default* rather than by validation. `maxTvl` initializes to `0` and the allowlist starts empty, so no deposit can succeed until the owner configures both. A vault nobody has configured is safe because nobody can enter it, not because the constructor proved anything.

The residual risk sits with whoever chooses to deposit into a given vault — the same place it sits for any permissionlessly deployed contract.

## Donation / inflation attack

See [OpenZeppelin's explanation](https://docs.openzeppelin.com/contracts/5.x/erc4626#security-concern-inflation-attack).

The vault does not inherit OpenZeppelin's `ERC4626` base contract — it extends `ERC20` and implements the interface directly — but it reproduces the same virtual-share mitigation: every share/asset conversion runs against `totalSupply + 10**6` claims and `totalAssets + 1` assets, with a fixed decimals offset of 6. The classic first-depositor attack is priced out by the same argument OZ makes.

A second, independent property blocks the donation half of the attack: **`totalAssets()` counts only collateral supplied to Morpho, the yield-token balance, and Morpho debt.** A raw loan-token transfer to the vault is invisible to NAV, so it cannot move share price, fee accrual, or the performance high-water mark. Donating collateral or yield tokens *does* move NAV, but as a gift to existing holders rather than a lever over a subsequent minter, because minting is priced off the NAV delta the depositor themselves produced.

## Re-entrancy

Every externally callable function that moves value on a *caller's* behalf carries OpenZeppelin's `nonReentrant`: `deposit`, `redeem`, `redeemInKind`, `rebalance`, `harvest`, and `accrueFees`. The slippage-protected `deposit`/`redeem` overloads inherit the guard from the base function they wrap. Between them these cover every path that calls out to Morpho, the swap pools, or transfers tokens on behalf of a third party.

The deliberate exceptions:

- **`onMorphoRepay` is not `nonReentrant`.** It is the repay callback Morpho invokes synchronously, mid-call, from inside `redeem`'s `_unwindSlice` — by the time it runs the guard is already `ENTERED` from `redeem`'s own modifier, so adding `nonReentrant` here would make the callback revert against itself. Instead it is authenticated: `require(msg.sender == address(MORPHO))`. That is sufficient because the only way `MORPHO.repay` calls back into this function is in response to a repay this same vault requested a few frames up the same call stack. An attacker cannot reach it directly, and cannot get Morpho to call it except by way of a repay the vault itself initiated.
- **`uniswapV3SwapCallback` is authenticated, not `nonReentrant`.** `SwapLib` calls the pool's `swap` directly, so the vault *is* the callback target — but the callback only pays the pool via `safeTransfer`, after checking `msg.sender` is one of the two immutable pool addresses. No vault state is read or written inside it, so there is no re-entrancy surface to protect, and the calling entry point's guard is already `ENTERED`.
- **Owner-only functions are not `nonReentrant`.** `setMaxSlippageBps`, `setManagementFeeBps`, `setPerformanceFeeBps`, `setFeeRecipient`, `grantEarlyAccess`, `revokeEarlyAccess`, `setMaxTvl`, and the three emergency-recovery functions are all `onlyOwner`. The fee setters call `_accrueFees()`, and `executeEmergencyRecovery` calls Morpho and transfers three tokens — real external calls, but reachable only by the owner. Access control, not the guard, is the operative defense for this group; the residual is an owner re-entering their own privileged function, which buys them nothing they cannot do with two transactions.

Two supporting properties:

- **Realized amounts are read from balance deltas, not trusted return values** — e.g. `redeem` computes `assets` as a collateral-balance delta. This is not primarily a re-entrancy mitigation (the guard already prevents a nested call into the same entry point), but it does mean pre-existing token dust cannot be credited to the wrong caller.
- **The allowlist hook (`_update`) is pure storage.** It runs on every mint/burn/transfer and makes no external call, so it adds no surface of its own.

## Permissionless rebalancing and sandwich risk

`rebalance()` and `harvest(uint256)` are callable by anyone. This is the classic dangerous shape — an attacker who can invoke a swap of *someone else's* funds, on their own schedule, can structure the full sandwich as a single transaction and repeat it. The reasoning for shipping it anyway is worth stating explicitly.

### Why it has to be permissionless

A levered position must be defended continuously. If rebalancing were gated on a keeper role, a keeper outage would convert a liveness failure into a solvency failure: the position would sit over-levered until the key came back, and Morpho would liquidate on its own schedule in the meantime. Scheduler contention, fee-vault depletion, and out-of-effort conditions are all real failure modes of the Cadence automation, and they correlate with market stress — exactly when a delever matters most. A permissionless direct call is the backstop that keeps an automation failure from becoming a loss of principal, and that backstop only works if it is open to whoever notices first.

There is a second, less obvious reason to accept the shape. `rebalance()` pays its caller nothing, so absent any MEV, no unaffiliated party would ever have a reason to call it — the backstop would exist on paper and never fire. The bounded extraction described below is what gives an outsider a reason to watch the position and act on it. It works as an implicit, self-funding keeper reward, and `maxSlippageBps` is effectively its fee schedule: the protocol is paying up to that bound in price impact for someone else to carry the monitoring and the gas.

### What bounds the exposure

- **No pricing input from the caller.** `rebalance()` takes no arguments. `harvest`'s only argument, `maximumYield`, is a cap — it can lower how much is sold, never raise it or steer the price.
- **The caller is paid nothing.** There is no keeper fee, rebate, refund, or callback. Fee shares minted during accrual go to `feeRecipient`, never to `msg.sender`, so triggering a rebalance is a pure gas cost.
- **Every swap is oracle-bounded.** Both keeper paths clamp each leg's marginal price to `maxSlippageBps` away from the oracle, enforced natively by the pool via `sqrtPriceLimitX96`. A swap too large to reach the band edge within tolerance partial-fills rather than reverting; a pool already pushed past the bound makes the leg a no-op rather than a bad fill. The attacker's own push is what disarms the trade.
- **The bound is on marginal price, i.e. on price impact.** The pool's fixed LP fee is a separate, known cost taken on the input and is not part of it.
- **Neither function can be re-armed at will.** `rebalance` only acts outside the band and leaves the position inside it, so a second call in the same block is a no-op. `harvest` only fires when the vault holds surplus yield and drives that surplus to zero. An attacker cannot loop either one; they must wait for the position to drift out on its own.
- **Flow's ordering model helps at the margin.** There is no [MEV-Boost](https://github.com/flashbots/mev-boost)-style system that systematizes extraction, and no individual node can deterministically dictate transaction ordering. An attacker must send many transactions, hope some land in the desired order, and be able to unwind those that do not. Still possible, but more complex and expensive.

### Residual

This bounds the loss per call, not the number of calls. An attacker who pre-positions a pool to just inside the `maxSlippageBps` bound and then triggers a rebalance captures up to that bound plus the LP fee on the volume traded, and can do so again on each genuine excursion. Aggregate cost over time is therefore unbounded and is a direct consequence of following the market — the same trade-off recorded in [`risk-disclosures.md` §1.2](./risk-disclosures.md).

Read as a keeper reward rather than a pure leak, it has one genuinely good property: the payoff scales with how far the position has drifted, so the incentive to call is largest exactly when calling matters most. Two limits are worth being explicit about, though:

- It selects for **MEV capability, not reliability**. The reward goes to whoever can move the pool, which is not necessarily the party who would have responded fastest or most honestly. It is a bounty, not a service contract, and nothing obliges the winner to show up next time.
- It is **paid by holders in price impact** — the same pocket an explicit keeper fee would come from. The differences are that this one never appears in the fee schedule, and that it is capped per call but not in aggregate.

The lever governing both the cost and the incentive is `maxSlippageBps`. It should be set as close to genuine execution cost as liveness allows: too tight and rebalances no-op when they are most needed, with nobody paid to retry them; too loose and every excursion is a subsidy.

### Why `deposit`/`redeem` are bounded differently

`deposit` and `redeem` swap without an oracle-derived price bound, but they only ever move the caller's *own* funds, so the sandwich shape above does not apply — a caller cannot be forced into a trade. Protection there is a caller-supplied minimum output, via the `deposit(assets, receiver, minSharesOut)` and `redeem(shares, receiver, owner, minAssetsOut)` overloads. Callers using the bare ERC-4626 signatures without a router-enforced bound are unprotected against ordinary sandwiching of their own transaction.

## Oracle manipulation

Two prices drive the vault, chosen to have different and deliberately narrow manipulation surfaces.

**Market oracle (collateral → loan).** Not the vault's to choose — it is whatever the Morpho market was created with, and Morpho enforces solvency against it regardless. Picking a different one for the vault's own accounting would let NAV disagree with the number that decides liquidation, so the vault reads the same feed Morpho does.

**Yield oracle (yield → loan).** `YieldTokenOracle` is a thin wrapper over the yield vault's own `convertToAssets`, rescaled to Morpho's 1e36 convention. A market price feed was the obvious alternative and was rejected: the yield token is an ERC-4626 share whose fair value *is* its redemption rate, so a feed would add a heartbeat, a staleness window, and an operator — three new failure modes — to reproduce a number the yield vault already publishes. Reading the vault directly means there is nothing to go stale independently of the asset being priced: the oracle can only fail if `convertToAssets` fails, and a yield vault broken that badly has already made the yield leg both unvaluable and unsellable.

`CONVERSION_SAMPLE` is fixed at construction rather than pricing a single share, because `convertToAssets(1)` floors away most of the precision on a share token worth more than one unit of its asset. Sampling a larger amount spreads that rounding floor over more shares.

The trade-off is real and worth stating plainly: **the vault marks the yield leg at the yield vault's redemption rate while its only exit for that leg is the AMM.** When the pool trades the share below its redemption rate, reported NAV exceeds what the position could actually realize. The exposure this creates to a manipulable `convertToAssets` — a yield vault whose exchange rate can be pushed within a block — is inherited wholesale; the vault performs no sanity check against the pool price.

**Why the swap bound is oracle-relative, not a fixed minimum-out.** An absolute `amountOutMinimum` on `rebalance`/`harvest` would have to be computed by the caller, which reintroduces exactly the caller-supplied pricing input that makes a permissionless entry point dangerous. Anchoring to the oracle keeps the bound caller-independent, and makes a manipulated *pool* a no-op rather than a bad fill. The cost of that choice is that a manipulated *oracle* moves the bound itself — which is why the two oracles are chosen to be as hard to move as the underlying market and the underlying yield vault respectively, rather than being independent feeds with their own operators.

## Owner trust

The owner is not a governance role with bounded powers; it is a trusted party. Concretely:

- **Emergency recovery is a one-way sweep to the owner.** After the 7-day timelock, `executeEmergencyRecovery` transfers the vault's entire collateral, yield, and loan balances to `owner()` and sets a flag that **permanently disables `redeem`, `redeemInKind`, and `rebalance`**. Shares survive but have no on-chain claim on anything; any distribution to holders is off-chain and discretionary. The timelock is the only protection, and it exists precisely so holders can exit during the window — `redeem` and `redeemInKind` stay open for all 7 days, and the scheduling emits `EmergencyRecoveryScheduled`. **Holders who do not monitor that event and exit in time are relying entirely on the owner's good faith.**
- **No other setter has a timelock.** Fee rates, fee recipient, `maxSlippageBps`, `maxTvl`, and the allowlist all take effect in the transaction that sets them. See [`risk-disclosures.md` §10](./risk-disclosures.md).
- **The allowlist is a transfer restriction the owner controls.** Revoking access does not trap principal — burns are always permitted, so `redeem`/`redeemInKind` stay open — but it does remove transferability.
- **Fee caps are the one hard bound.** Management is capped at 10 %/yr and performance at 50 % in immutable constants; `maxSlippageBps` is capped at 10 %. The owner cannot exceed these.

Mitigations for all of the above are operational (multisig, monitoring on `EmergencyRecoveryScheduled`, off-chain governance) and outside the scope of the contract. See [`operations.md`](./operations.md).

## Known gaps

- **NAV is mark-to-oracle, not mark-to-exit.** Redeeming at a moment when the pool prices the yield leg below its redemption rate realizes less than `convertToAssets` implied. This is disclosed rather than mitigated.
- **The yield source's exchange rate is trusted.** A yield vault whose `convertToAssets` can be manipulated within a block moves both the NAV mark and the swap bound in the same direction.
- **`maxTvl` is a soft cap.** It gates new deposits only; appreciation can carry the position past it, and lowering it never unwinds. See [`risk-disclosures.md` §8](./risk-disclosures.md).
