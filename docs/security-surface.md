# FCMVault — State-Modifying Surface & Dependencies

## 1. State-Modifying External Functions

### 1a. Directly declared on FCMVault

Access-control scheme: **`owner`** (owner-only — `onlyOwner` and
`DEFAULT_ADMIN_ROLE` resolve to the same account), **`early-access`** (caller/
receiver must hold `EARLY_ACCESS_ROLE`), or **`public`** (any caller).

| Function | Access | Invokes (state-modifying deps) |
|---|---|---|
| `setMaxSlippageBps(uint256)` | owner | *(none — storage + event only)* |
| `setManagementFeeBps(uint256)` | owner | `MORPHO.accrueInterest` |
| `setPerformanceFeeBps(uint256)` | owner | `MORPHO.accrueInterest` |
| `setFeeRecipient(address)` | owner | `MORPHO.accrueInterest` |
| `accrueFees()` | public | `MORPHO.accrueInterest` |
| `deposit(uint256 assets, address receiver)` | early-access | `MORPHO.accrueInterest`, `collateral.safeTransferFrom`, `MORPHO.supplyCollateral`, `MORPHO.borrow`, `Router.exactInputSingle` |
| `redeem(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `Router.exactInputSingle`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer` |
| `redeemInKind(uint256 shares, address receiver, address owner)` | public | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay`, `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer` |
| `rebalance()` | public | `MORPHO.accrueInterest`, `MORPHO.borrow`, `Router.exactInputSingle`, `MORPHO.repay` |
| `setMaxTvl(uint256)` | owner | *(none — storage + event only)* |
| `scheduleEmergencyRecovery()` | owner | *(none — storage + event only)* |
| `cancelEmergencyRecovery()` | owner | *(none — storage + event only)* |
| `executeEmergencyRecovery()` | owner | `MORPHO.accrueInterest`, `loan.safeTransferFrom`, `MORPHO.repay` (via `repayAll`), `MORPHO.withdrawCollateral`, `collateral.safeTransfer`, `yield.safeTransfer`, `loan.safeTransfer` |

> Notes on `public` rows:
> - `deposit` (early-access) also reverts while a recovery is pending or after it executes.
> - `redeem` / `redeemInKind` are callable by anyone, but a non-owner caller must
>   hold sufficient share allowance from `owner`; burns bypass the
>   `EARLY_ACCESS_ROLE` gate so removed holders can still exit.
> - `rebalance` reverts once `recovered`.
>
> Excluded as read-only/non-mutating: `totalAssets`, `maxDeposit`, `maxMint`,
> all public getters, and the reverting `mint`/`withdraw` (both `pure`).

### 1b. Inherited — ERC20 (share token)

- `transfer(address,uint256)` — gated by `_update` (both parties need `EARLY_ACCESS_ROLE`; burns exempt)
- `transferFrom(address,address,uint256)` — same gating
- `approve(address,uint256)`


### 1c. Inherited — AccessControl

- `grantRole(bytes32,address)`
- `revokeRole(bytes32,address)`
- `renounceRole(bytes32,address)`

### 1d. Inherited — Ownable2Step

- `transferOwnership(address)` (`onlyOwner`)
- `acceptOwnership()` (pending owner)
- `renounceOwnership()` (`onlyOwner`)

---

## 2. State-Modifying External Dependencies

Top level = external contract; sub-level = state-modifying functions FCMVault
actually calls (directly or via `MarketLib` / `SwapLib`).

- **Morpho Blue singleton** — `IMorpho` at `0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f` (via `MarketLib`)
  - `accrueInterest(MarketParams)`
  - `supplyCollateral(MarketParams, uint256, address, bytes)`
  - `borrow(MarketParams, uint256, uint256, address, address)`
  - `repay(MarketParams, uint256, uint256, address, bytes)` — invoked directly and via `repayAll`
  - `withdrawCollateral(MarketParams, uint256, address, address)`

- **FlowSwap V3 SwapRouter02** — `ISwapRouter` at `0xeEDC6Ff75e1b10B903D9013c358e446a73d35341` (via `SwapLib`)
  - `exactInputSingle(ExactInputSingleParams)` — used by both `swapExactIn` (no limit) and `swapExactInToLimit` (with `sqrtPriceLimitX96`)

- **Collateral token (vault asset)** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves Morpho)*
  - `safeTransferFrom(...)` (deposit)
  - `safeTransfer(...)` (redeem payout, redeemInKind, executeEmergencyRecovery)

- **Loan token (debt token)** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves Morpho + SwapRouter)*
  - `safeTransferFrom(...)` (redeemInKind, executeEmergencyRecovery)
  - `safeTransfer(...)` (executeEmergencyRecovery remainder sweep)

- **Yield token** — `IERC20` / `SafeERC20`
  - `forceApprove(...)` *(constructor only — approves SwapRouter)*
  - `safeTransfer(...)` (redeemInKind, executeEmergencyRecovery)

> Excluded as read-only: `MORPHO.position`, `MORPHO.market`, `IOracle.price`
> (market + yield oracles), `IUniswapV3Pool.slot0`, and all ERC20 `balanceOf`
> reads.
