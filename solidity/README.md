# Solidity (Foundry)

Foundry project for the FCM contracts on Flow EVM. See the [Foundry book](https://book.getfoundry.sh/) for tool documentation.

## Build & test

```shell
forge build
forge test
forge fmt
```

Or from the repo root: `make ci`.

To also run the yield-oracle fork tests against live mainnet state (they
auto-skip when the env var is unset):

```shell
make mainnet-fork-test    # from the repo root
```

## Mainnet deployment

Deployments target **Flow EVM mainnet only** (chain id 747, RPC
`https://mainnet.evm.nodes.onflow.org`) and are **manual** — never run from
CI. Every dependency the vault uses (Morpho Blue, FlowSwap V3, tokens, the
Pyth market oracle) is already deployed; addresses live in
[`deployments/mainnet.json`](./deployments/mainnet.json), and each script
asserts the RPC's chain id matches the config before doing anything.

### What gets deployed

| Contract | Source | Notes |
| :--- | :--- | :--- |
| `YieldTokenOracle` | `src/YieldTokenOracle.sol` | NAV price of FUSDEV in PYUSD0 from FUSDEV's own ERC4626 exchange rate (`convertToAssets`), Morpho `IOracle` convention. Deployed automatically by `DeployVault` when `yieldOracle` in the config is zero; afterwards, record its address in the config so later deploys reuse it. |
| `FCMVault` | `src/FCMVault.sol` | The ERC-4626 vault. The broadcaster becomes admin/owner. |

### Runbook

Export a deployer key first (`PRIVATE_KEY=0x...`). The deployer becomes the
vault's admin and owner, pays gas in FLOW, and needs PYUSD0 (seeding) and a
little WETH (live check).

**Always run the `-dry` variant first.** Dry runs fork-simulate the exact
transaction sequence against live mainnet state and cost nothing.

```shell
# 1. Read-only report: market, pools, oracle prices, your balances.
DEPLOYER=0x<your address> make mainnet-status

# 2. One-time: supply PYUSD0 borrow liquidity to the Morpho market.
#    (SEED_AMOUNT is in PYUSD0 base units; PYUSD0 has 6 decimals.)
SEED_AMOUNT=10000000000 make mainnet-seed-market-dry
SEED_AMOUNT=10000000000 make mainnet-seed-market

# 3. Deploy yield oracle + vault, grant EARLY_ACCESS_ROLE, set TVL limit.
#    (MAX_TVL is in WETH base units; 18 decimals.)
MAX_TVL=100000000000000000000 make mainnet-deploy-dry
MAX_TVL=100000000000000000000 make mainnet-deploy

# 4. Live integration check: deposit then redeem a small amount of WETH.
VAULT=0x<deployed vault> make mainnet-check-dry
VAULT=0x<deployed vault> make mainnet-check
```

After a real deploy:

- record the `FCMVault` and `YieldTokenOracle` addresses in the root
  `README.md` deployments table;
- put the yield oracle address into `deployments/mainnet.json` so future
  vault deploys reuse it;
- commit the `broadcast/**/747/run-latest.json` files — they are the
  deployment record.

### Script reference

| Script | Purpose | Env |
| :--- | :--- | :--- |
| `script/Status.s.sol` | Read-only state report; never broadcasts | `DEPLOYER` (optional) |
| `script/SeedMarket.s.sol` | Supply loan token to the Morpho market | `SEED_AMOUNT` (required) |
| `script/DeployVault.s.sol` | Deploy oracle (if needed) + vault + admin setup | `MAX_TVL` (required), `VAULT_NAME`, `VAULT_SYMBOL`, `EARLY_ACCESS_GRANTEES` (comma-separated) |
| `script/LiveCheck.s.sol` | Real deposit→redeem against a live vault | `VAULT` (required), `CHECK_AMOUNT` (default 0.01 WETH), `MIN_ROUNDTRIP_BPS` (default 9700) |

Notes:

- The yield oracle prices FUSDEV at its ERC4626 redemption value (NAV),
  which cannot be moved by trading against the FlowSwap pool. It reflects
  redemption value rather than the pool's executable swap price; arbitrage
  keeps the two close while FUSDEV redemptions remain permissionless.
- `LiveCheck` spends real funds (swap fees + price impact, bounded by
  `MIN_ROUNDTRIP_BPS`). Everything it needs is read from the vault itself,
  so it works against any FCMVault address.
- Key handling: use a dedicated deployer EOA. Prefer `PRIVATE_KEY=$(...)`
  from a secret store or a leading-space export over typing the key into
  your shell history; `cast wallet` keystores also work with
  `forge script --account`.

### Rehearsing the full sequence locally (fork-based deployment test)

```shell
make mainnet-rehearse    # from the repo root
```

This runs the **entire production deployment sequence against an anvil fork
of live mainnet** — real Morpho, FlowSwap, Pyth, and token contracts; state
carried between steps; zero real funds and no `PRIVATE_KEY` needed. Run it
before any real deployment: it proves the scripts work against *current*
mainnet state, which the per-script `-dry` targets cannot (each dry run
simulates in isolation, so `DeployVault` can't see `SeedMarket`'s effect).

What [`script/rehearse.sh`](./script/rehearse.sh) does:

1. **Starts `anvil --fork-url <mainnet>`** with `--auto-impersonate`. The
   fork preserves chain id 747, so the scripts' config chain-id guard
   passes unchanged.
2. **Funds anvil's dev account** (`0xf39F…2266`, a publicly-known test key)
   with WETH and PYUSD0 by impersonating the largest on-chain holders — the
   FlowSwap pools — and transferring from them, after giving the pools gas
   via `anvil_setBalance`.
3. **Freshens the Pyth market oracle if stale.** The Morpho market's
   WETH/USD oracle reverts with `StalePrice` when the Pyth feed hasn't been
   pushed within `PRICE_FEED_MAX_AGE` (1 hour). The script pulls a fresh
   signed update from [Hermes](https://hermes.pyth.network) and posts it via
   `pyth.updatePriceFeeds` — permissionless and fee-paid, exactly the remedy
   you would use on real mainnet if deposits revert with a stale oracle.
4. **Runs the three broadcast scripts in production order** against the
   fork: `SeedMarket` (default 50k PYUSD0) → `DeployVault` (yield oracle +
   vault + admin setup, default `MAX_TVL` 100 WETH) → `LiveCheck`
   (deposit/redeem round-trip, default 0.01 WETH), parsing the vault
   address out of the deploy logs.
5. **Cleans up**: kills anvil and deletes the rehearsal's
   `broadcast/*/747/` records so they cannot masquerade as real mainnet
   deployment records (it refuses to start if uncommitted broadcast records
   are already present, since cleanup couldn't tell them apart).

Knobs (all optional env vars): `FLOW_MAINNET_RPC`, `ANVIL_PORT`,
`SEED_AMOUNT`, `MAX_TVL`, `CHECK_AMOUNT`. Requires `anvil`/`cast`/`forge`
(Foundry), `curl`, and `python3`.

<!-- Cadence: once the VaultRebalancer (PR #38) merges, its deployment step
     (flow CLI, consumes the FCMVault address) gets a section here. -->
