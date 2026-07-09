# FCMVault — State-Modifying Surface & Dependencies

## 1. State-Modifying External Functions

### 1a. Directly declared on FCMVault

_Impact_ references the §2 dependency failure modes each function is exposed to
through its invoked deps. Dependency: **M** Morpho · **R** Router. Mode: **A**
availability · **B** byzantine. `—` = no external dependency (impact is
config/logic-only). The three tokens (collateral, loan, yield) are omitted (see §2).

| Function | Access | Invokes (state-modifying deps) | Impact (§2 modes) |
|---|---|---|---|
| `setMaxSlippageBps(uint256)` | owner | *(none — storage + event only)* | — |
| `setManagementFeeBps(uint256)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `setPerformanceFeeBps(uint256)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `setFeeRecipient(address)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `accrueFees()` | public | `MORPHO.accrueInterest` | M(A/B) |
| `deposit(uint256 assets, address receiver)` | early-access | `MORPHO.accrueInterest`, `collateral.safeTransferFrom`, `MORPHO.supplyCollateral`, `MORPHO.borrow`, `Router.exactInputSingle` | M(A/B), R(A/B) |
| `redeem(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `Router.exactInputSingle`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer` | M(A/B), R(A/B) |
| `redeemInKind(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer` | M(A/B) |
| `rebalance()` | public | `MORPHO.accrueInterest`, `MORPHO.borrow`, `Router.exactInputSingle`, `MORPHO.repay` | M(A/B), R(A/B) |
| `setMaxTvl(uint256)` | owner | *(none — storage + event only)* | — |
| `scheduleEmergencyRecovery()` | owner | *(none — storage + event only)* | — |
| `cancelEmergencyRecovery()` | owner | *(none — storage + event only)* | — |
| `executeEmergencyRecovery()` | owner | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay` (via `repayAll`), `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer`, `loan.safeTransfer` | M(A/B) |

### 1b. Inherited — ERC20 (share token)

_Assumed safe:_ these run OpenZeppelin's audited ERC20 accounting unchanged; the only vault-specific logic is the `_update` allowlist hook, which can only *restrict* who holds shares.

- `transfer(address,uint256)` — gated by `_update` (both parties need `EARLY_ACCESS_ROLE`; burns exempt)
- `transferFrom(address,address,uint256)` — same gating
- `approve(address,uint256)`

### 1c. Inherited — AccessControl

_Assumed safe:_ these run OpenZeppelin's audited role machinery and have no functionality specific to FCMVault.

- `grantRole(bytes32,address)`
- `revokeRole(bytes32,address)`
- `renounceRole(bytes32,address)`

### 1d. Inherited — Ownable2Step

_Assumed safe:_ these run OpenZeppelin's audited two-step ownership handshake and have no functionality specific to FCMVault.

- `transferOwnership(address)` (`onlyOwner`)
- `acceptOwnership()` (pending owner)
- `renounceOwnership()` (`onlyOwner`)

---

## 2. State-Modifying External Dependencies

For each dependency, failure impact is split into **availability failure**
(calls revert / contract unreachable) and **byzantine failure** (executes but
returns false results or acts maliciously). Each item names an affected
capability and its outcome: 
- **inaccessible funds** (holders can't withdraw)
- **lost funds** (value stolen or permanently lost)
- **NAV manipulation** (accounting/price corruption)
- **deposits halted**
- **rebalancing halted**

### **Morpho Blue singleton** — `IMorpho` at `0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f` (via `MarketLib`)

  - `accrueInterest(MarketParams)`
  - `supplyCollateral(MarketParams, uint256, address, bytes)`
  - `borrow(MarketParams, uint256, uint256, address, address)`
  - `repay(MarketParams, uint256, uint256, address, bytes)`
  - `withdrawCollateral(MarketParams, uint256, address, address)`

#### Availability
- Blocks all deposits, withdrawals, rebalances, and emergency recoveries -> inaccessible funds, deposits/rebalancing halted

#### Byzantine
- collateral custody -> lost funds (collateral seized or withheld)
- debt & position accounting -> NAV manipulation

### **FlowSwap V3 SwapRouter02** — `ISwapRouter` at `0xeEDC6Ff75e1b10B903D9013c358e446a73d35341` (via `SwapLib`)
  - `exactInputSingle(ExactInputSingleParams)` — used by both `swapExactIn` (no limit) and `swapExactInToLimit` (with `sqrtPriceLimitX96`)

#### Availability
- `deposit`, `redeem`, and `rebalance` revert -> deposits/rebalancing halted
- `redeemInKind` / `executeEmergencyRecovery` are swap-free -> still works

#### Byzantine
- `deposit` / `redeem` swaps (no min-out) -> lost funds (bad fills siphon value)
- `rebalance` swaps (bounded by `sqrtPriceLimitX96`) -> lost funds (bounded by price limit)

### **Collateral token (vault asset)** — `IERC20` / `SafeERC20`
  - `safeTransferFrom(...)` (deposit)
  - `safeTransfer(...)` (redeem payout, redeemInKind, executeEmergencyRecovery)

#### Availability
- Blocks all deposits, withdrawals, rebalances, and emergency recoveries -> inaccessible funds

#### Byzantine
- unit of account & custody asset -> lost funds
- fee-on-transfer / rebasing / arbitrary mint -> NAV manipulation

### **Loan token (debt token)** — `IERC20` / `SafeERC20`
  - `safeTransferFrom(...)` (redeemInKind, executeEmergencyRecovery)
  - `safeTransfer(...)` (executeEmergencyRecovery remainder sweep)

#### Availability
- Blocks all deposits, withdrawals, rebalances, and emergency recoveries -> inaccessible funds

#### Byzantine
- debt unit of account -> lost funds
- corrupts repay/borrow settlement & swap proceeds -> NAV manipulation

### **Yield token** — `IERC20` / `SafeERC20`
  - `safeTransfer(...)` (redeemInKind, executeEmergencyRecovery)

#### Availability
- Blocks all deposits, withdrawals, rebalances, and emergency recoveries -> inaccessible funds

#### Byzantine
- yield-leg holding -> lost funds
- corrupts NAV & unwind proceeds -> NAV manipulation
