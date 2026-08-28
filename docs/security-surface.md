# FCM Security Surface

Per state-modifying external function: which dependencies it calls, and what happens when a dependency is unavailable. Complements [`risk-disclosures.md`](./risk-disclosures.md), which covers costs that exist even when every dependency behaves honestly.

Availability claims are verified in [`FCMDependencyFailures.t.sol`](../solidity/test/FCMDependencyFailures.t.sol) and, for Morpho's own health-check behavior, against the real deployed Morpho Blue in [`EmergencyRecoveryFork.t.sol`](../solidity/test/fork/EmergencyRecoveryFork.t.sol).

## Functions

Key: 🟣 Morpho · 🟢 Router · 🔵 Market oracle · 🟠 Yield oracle · `—` no dependency.

| Function                                 | Access        | Dependency                                          |
| ---------------------------------------- | ------------- | --------------------------------------------------- |
| `accrueFees()`                           | public        | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle           |
| `rebalance()`                            | public        | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle, 🟢 Router |
| `harvest(uint256)`                       | public        | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle, 🟢 Router |
| `scheduleEmergencyRecovery()`            | owner         | —                                                   |
| `cancelEmergencyRecovery()`              | owner         | —                                                   |
| `executeEmergencyRecovery()`             | owner         | 🟣 Morpho                                            |
| `redeemInKind(uint256,address,address)`  | public        | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle           |
| `setFeeRecipient(address)`               | owner         | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle           |
| `setManagementFeeBps(uint256)`           | owner         | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle           |
| `setMaxSlippageBps(uint256)`             | owner         | —                                                   |
| `setMaxTvl(uint256)`                     | owner         | —                                                   |
| `setPerformanceFeeBps(uint256)`          | owner         | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle           |
| `grantEarlyAccess(address)`              | owner         | —                                                   |
| `revokeEarlyAccess(address)`             | owner         | —                                                   |
| `deposit(uint256,address)`               | early-access  | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle, 🟢 Router |
| `redeem(uint256,address,address)`        | public        | 🟣 Morpho, 🔵 Market oracle, 🟠 Yield oracle, 🟢 Router |
| `transfer(address,uint256)`¹             | holder        | —                                                   |
| `transferFrom(address,address,uint256)`¹ | holder        | —                                                   |
| `approve(address,uint256)`               | holder        | —                                                   |
| `transferOwnership(address)`             | owner         | —                                                   |
| `acceptOwnership()`                      | pending owner | —                                                   |
| `renounceOwnership()`                    | owner         | —                                                   |

¹ Gated by the `_update` allowlist hook — both parties need `earlyAccess`; otherwise unmodified OpenZeppelin accounting.

Every function above tagged with Morpho and an oracle (except `executeEmergencyRecovery`) calls `_accrueFees()`, which prices both legs via `totalAssets()` against both oracles — so the oracle tags only become real once the vault holds nonzero debt or yield. A fresh or fully-unwound vault skips both oracle reads entirely.

`executeEmergencyRecovery` never calls either oracle directly. It only succeeds once debt is zero, and that path is fully oracle-independent — confirmed on a Flow mainnet fork with the market oracle forced to revert throughout. While debt remains outstanding it reverts regardless of dependency health, because Morpho's health check computes zero borrowing power against the now-empty collateral.

## Impact during outage

### Morpho Blue — `IMorpho`

Unavailable: deposits, redemptions, rebalancing, harvesting, and recovery all halt. If it stays unavailable permanently, all vault funds are permanently stuck.

### Market oracle — `IOracle`

Unavailable: deposits, redemptions, rebalancing, and harvesting halt. `executeEmergencyRecovery` remains available and can still recover all funds.

### Yield oracle — `YieldTokenOracle`

Unavailable: deposits, redemptions, rebalancing, and harvesting halt. `executeEmergencyRecovery` remains available and can still recover all funds.

### Router — `ISwapRouter02`

Unavailable: deposits, redemptions, rebalancing, and harvesting halt. `redeemInKind` and `executeEmergencyRecovery` remain available as exit paths.
