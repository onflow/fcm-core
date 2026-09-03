# FCM Security Surface

Per state-modifying external function: which dependencies it calls, and what happens when one of them is unavailable (reverts on every call).

This is the **availability** reference. Adversarial analysis lives in [`security.md`](./security.md); costs that exist even when every dependency behaves honestly live in [`risk-disclosures.md`](./risk-disclosures.md).

## Functions

Key: ✅ works during outage · ❌ halted during outage.

The table describes a **typical funded, levered vault**. Verdicts in the two pool columns can flip to ✅ for a vault in a degenerate state — see [State dependence](#state-dependence).

| Function                                      | Access                   | Morpho | Market oracle | Yield oracle | Yield/loan pool | Collateral/loan pool |
| --------------------------------------------- | ------------------------ | :----: | :-----------: | :----------: | :-------------: | :------------------: |
| `accrueFees()`                                | public                   |   ❌   |      ❌       |      ❌      |       ✅        |          ✅          |
| `rebalance()`                                 | public                   |   ❌   |      ❌       |      ❌      |       ❌        |          ✅          |
| `harvest(uint256)`                            | public                   |   ❌   |      ❌       |      ❌      |       ❌        |          ❌          |
| `deposit(uint256,address)`                    | receiver allowlisted¹    |   ❌   |      ❌       |      ❌      |       ❌        |          ✅          |
| `redeem(uint256,address,address)`             | share owner / approved   |   ❌   |      ❌       |      ❌      |       ❌        |          ❌          |
| `redeemInKind(uint256,address,address)`       | share owner / approved   |   ❌   |      ❌       |      ❌      |       ✅        |          ✅          |
| `scheduleEmergencyRecovery()`                 | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `cancelEmergencyRecovery()`                   | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `executeEmergencyRecovery()`                  | owner                    |   ❌   |      ✅       |      ✅      |       ✅        |          ✅          |
| `setFeeRecipient(address)`                    | owner                    |   ❌   |      ❌       |      ❌      |       ✅        |          ✅          |
| `setManagementFeeBps(uint16)`                 | owner                    |   ❌   |      ❌       |      ❌      |       ✅        |          ✅          |
| `setPerformanceFeeBps(uint16)`                | owner                    |   ❌   |      ❌       |      ❌      |       ✅        |          ✅          |
| `setMaxSlippageBps(uint16)`                   | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `setMaxTvl(uint256)`                          | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `grantEarlyAccess(address)`                   | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `revokeEarlyAccess(address)`                  | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `transfer(address,uint256)`²                  | holder                   |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `transferFrom(address,address,uint256)`²      | approved spender         |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `approve(address,uint256)`                    | public                   |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `transferOwnership(address)`                  | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `acceptOwnership()`                           | pending owner            |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `renounceOwnership()`                         | owner                    |   ✅   |      ✅       |      ✅      |       ✅        |          ✅          |
| `onMorphoRepay(uint256,bytes)`³               | Morpho only              |   —    |       —       |      —       |        —        |          —           |
| `uniswapV3SwapCallback(int256,int256,bytes)`³ | the two configured pools |   —    |       —       |      —       |        —        |          —           |

¹ `deposit` has no gate on `msg.sender`. The allowlist is enforced on the _receiver_, via `_mint` → `_update`, so anyone may fund a deposit for an allowlisted account.
² Gated by the `_update` allowlist hook — both parties need `earlyAccess`; otherwise unmodified OpenZeppelin accounting.
³ Callbacks, listed for completeness because they are externally callable and state-modifying. They have no independent availability verdict: each is authenticated to its caller (`MORPHO`, or one of the two configured pools) and can only run inside a parent call the vault itself initiated, so its dependencies are already accounted for in the `redeem` / `harvest` / `rebalance` / `deposit` rows. `onMorphoRepay` withdraws collateral and may swap on the collateral/loan pool; `uniswapV3SwapCallback` only pays the pool with a `safeTransfer` and touches nothing else.

The slippage-protected overloads `deposit(uint256,address,uint256)` and `redeem(uint256,address,address,uint256)` are thin wrappers that call the base function and then check the output, so they inherit their base row exactly.

## Why the Morpho and oracle columns are unconditional

Three separate mechanisms hit these dependencies, and between them they leave no state in which a listed ❌ becomes a ✅:

1. **`_accrueFees()`** runs at the top of `deposit`, `redeem`, `redeemInKind`, `rebalance`, `harvest`, `accrueFees`, and the three fee setters — and nowhere else. It calls `MORPHO.accrueInterest` and then `totalAssets()`, which reads **both** oracle `price()` functions unconditionally — the yield-oracle read is an argument to a `mulDiv`, so Solidity evaluates it even when the yield balance is zero.
2. **The `logsVaultState` modifier** wraps `rebalance`, `harvest`, `deposit`, `redeem`, and `redeemInKind`. It runs _after_ the body and emits `VaultState(...)`, reading Morpho twice and both oracles again. This is why a zero-amount `deposit`, a `redeem(0, …)`, an in-band `rebalance`, and a no-op `harvest` all still fail under a Morpho or oracle outage despite doing no work.
3. **Morpho's own health check.** `borrow` and `withdrawCollateral` call Morpho's internal `_isHealthy`, which reads the _market_ oracle whenever `borrowShares != 0`. So the market-oracle ❌ on `deposit`, `redeem`, and `redeemInKind` has a second, independent cause beyond `_accrueFees()`.

`executeEmergencyRecovery` is the one entry point that never reads either oracle directly: it does not accrue fees, is not wrapped in `logsVaultState`, and its `withdrawCollateral` short-circuits Morpho's health check once borrow shares are zero. That is what makes the full-recovery path oracle-independent — confirmed on a Flow mainnet fork with the market oracle forced to revert throughout.

It is blocked while debt is outstanding **and** collateral is nonzero, because Morpho refuses to release the collateral. With zero collateral it skips `withdrawCollateral` entirely and succeeds regardless of debt.

## State dependence

Only the two pool columns are state-dependent. Each ❌ below becomes ✅ when the corresponding swap is skipped:

| Cell                                       | ❌ requires                                                                                                                   |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `rebalance` / yield-loan                   | LTV outside the band. Delever also needs a nonzero yield balance; lever-up needs no pending recovery. In-band → no pool read. |
| `harvest` / yield-loan and collateral-loan | A nonzero surplus (`yield > debt` valued in yield) and `maximumYield > 0`. Otherwise the function returns before either leg.  |
| `deposit` / yield-loan                     | A nonzero borrow (`toBorrow > 0`). A position already at or above the deposit-target LTV skips the swap.                      |
| `redeem` / yield-loan                      | A nonzero yield slice.                                                                                                        |
| `redeem` / collateral-loan                 | The yield sale not exactly matching the debt slice — a surplus or a shortfall. Practically always true.                       |

Note that `harvest`'s collateral-loan leg is reached even when leg 1 is skipped by the price bound: `loanOut == 0` still flows into the second swap's limit computation, which reads `slot0`.

## Test coverage

Honest accounting of what is actually asserted rather than derived by inspection.

- [`FCMDependencyFailures.t.sol`](../test/FCMDependencyFailures.t.sol) covers every fund-path row — `deposit`, `redeem`, `redeemInKind`, `rebalance`, `harvest`, `executeEmergencyRecovery`, `accrueFees` — against all five dependencies. Two cases carry most of the weight: both `rebalance` branches surviving a collateral/loan-pool outage, which is the claim behind splitting `harvest` out of `rebalance`, and `accrueFees` surviving either pool outage, since it is the only `_accrueFees` consumer without `logsVaultState`.
- [`EmergencyRecoveryFork.t.sol`](../test/fork/EmergencyRecoveryFork.t.sol) confirms, against the real deployed Morpho Blue, that the recovery path stays available with the market oracle reverting throughout.

The owner-setter and ERC-20/ownership rows are derived by reading the call graph rather than asserted — they are configuration and token plumbing, not fund-path availability.

## Impact during outage

### Morpho Blue — `IMorpho`

Deposits, redemptions, rebalancing, harvesting, fee accrual, the fee setters, and recovery all halt. If it stays unavailable permanently, all vault funds are permanently stuck. Share transfers and the non-fee owner setters keep working, but there is nothing behind the shares to reach.

### Market oracle — `IOracle`

Deposits, redemptions, rebalancing, harvesting, `accrueFees()`, and the three `_accrueFees`-calling setters (`setFeeRecipient`, `setManagementFeeBps`, `setPerformanceFeeBps`) all halt. `executeEmergencyRecovery` remains available and can still recover all funds.

### Yield oracle — `YieldTokenOracle`

Identical blast radius to the market oracle: same set halts, `executeEmergencyRecovery` remains available.

### Yield/loan pool — `IUniswapV3Pool`

Deposits, redemptions, rebalancing, and harvesting halt. `redeemInKind` and `executeEmergencyRecovery` remain available as exit paths, and every owner setter plus `accrueFees()` keeps working.

### Collateral/loan pool — `IUniswapV3Pool`

Redemptions and harvesting halt — both route excess loan → collateral through this pool (`redeem` via `onMorphoRepay`). Deposits, rebalancing, `redeemInKind`, `executeEmergencyRecovery`, `accrueFees()`, and all owner setters remain available; none of them touch it.
