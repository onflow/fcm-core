# FCMVault — State-Modifying Surface & Dependencies

## 1. State-Modifying External Functions

### 1a. Directly declared on FCMVault

Access-control scheme: **`owner`** (owner-only — `onlyOwner` and
`DEFAULT_ADMIN_ROLE` resolve to the same account), **`early-access`** (caller/
receiver must hold `EARLY_ACCESS_ROLE`), or **`public`** (any caller).

| Function | Access | Invokes (state-modifying deps) | Impact (§2 modes) |
|---|---|---|---|
| `setMaxSlippageBps(uint256)` | owner | *(none — storage + event only)* | — |
| `setManagementFeeBps(uint256)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `setPerformanceFeeBps(uint256)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `setFeeRecipient(address)` | owner | `MORPHO.accrueInterest` | M(A/B) |
| `accrueFees()` | public | `MORPHO.accrueInterest` | M(A/B) |
| `deposit(uint256 assets, address receiver)` | early-access | `MORPHO.accrueInterest`, `collateral.safeTransferFrom`, `MORPHO.supplyCollateral`, `MORPHO.borrow`, `Router.exactInputSingle` | M(A/B), C(A/B), R(A/B) |
| `redeem(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `Router.exactInputSingle`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer` | M(A/B), R(A/B), C(A/B) |
| `redeemInKind(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer` | M(A/B), L(A/B), C(A/B), Y(A/B) |
| `rebalance()` | public | `MORPHO.accrueInterest`, `MORPHO.borrow`, `Router.exactInputSingle`, `MORPHO.repay` | M(A/B), R(A/B) |
| `setMaxTvl(uint256)` | owner | *(none — storage + event only)* | — |
| `scheduleEmergencyRecovery()` | owner | *(none — storage + event only)* | — |
| `cancelEmergencyRecovery()` | owner | *(none — storage + event only)* | — |
| `executeEmergencyRecovery()` | owner | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay` (via `repayAll`), `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer`, `loan.safeTransfer` | M(A/B), L(A/B), C(A/B), Y(A/B) |

_Impact_ references the §2 dependency failure modes each function is exposed to
through its invoked deps. Dependency: **M** Morpho · **R** Router · **C** collateral
token · **L** loan token · **Y** yield token. Mode: **A** availability · **B**
byzantine. `—` = no external dependency (impact is config/logic-only).

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
returns false results or acts maliciously).

### **Morpho Blue singleton** — `IMorpho` at `0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f` (via `MarketLib`)

  - `accrueInterest(MarketParams)`
  - `supplyCollateral(MarketParams, uint256, address, bytes)`
  - `borrow(MarketParams, uint256, uint256, address, address)`
  - `repay(MarketParams, uint256, uint256, address, bytes)`
  - `withdrawCollateral(MarketParams, uint256, address, address)`

#### Availability
Bricks every mutating flow, including both exit paths and recovery -> funds locked.

#### Byzantine
Custodies collateral and owns debt accounting -> collateral seizure or NAV corruption -> total loss.

### **FlowSwap V3 SwapRouter02** — `ISwapRouter` at `0xeEDC6Ff75e1b10B903D9013c358e446a73d35341` (via `SwapLib`)
  - `exactInputSingle(ExactInputSingleParams)` — used by both `swapExactIn` (no limit) and `swapExactInToLimit` (with `sqrtPriceLimitX96`)

#### Availability
Bricks deposit, redeem, and rebalance -> swap-free `redeemInKind` and recovery still exit.

#### Byzantine
Deposit/redeem swaps carry no min-out -> arbitrarily bad fills siphon value per swap (rebalance partly bounded by `sqrtPriceLimitX96`).

### **Collateral token (vault asset)** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves Morpho)*
  - `safeTransferFrom(...)` (deposit)
  - `safeTransfer(...)` (redeem payout, redeemInKind, executeEmergencyRecovery)

#### Availability
Bricks deposit and every asset payout (redeem, redeemInKind, recovery) -> funds locked.

#### Byzantine
Unit of account and custody asset -> loss of funds, NAV manipulation

### **Loan token (debt token)** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves Morpho + SwapRouter)*
  - `safeTransferFrom(...)` (redeemInKind, executeEmergencyRecovery)
  - `safeTransfer(...)` (executeEmergencyRecovery remainder sweep)

#### Availability
Underpins borrow/repay/swaps -> bricks deposit, redeem, redeemInKind, rebalance, and recovery -> funds locked.

#### Byzantine
Debt unit of account -> loss of funds, NAV manipulation

### **Yield token** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves SwapRouter)*
  - `safeTransfer(...)` (redeemInKind, executeEmergencyRecovery)

#### Availability
Gates the yield leg -> bricks deposit, redeem, redeemInKind, rebalance, and recovery -> funds locked.

#### Byzantine
Yield-leg holding -> loss of funds, NAV manipulation.
