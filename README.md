# flow-credit-markets

Users holding an asset are seeking higher returns than the direct yield opportunities of that asset. Using the asset as collateral to borrow a debt token can gain those higher yields, but requires permanent user interaction to keep asset exposure, maximize yield and prevent liquidation.
We utilize flow's unique feature of scheduled transactions to automate this process, constantly adjusting the position to keep asset exposure at 100%, maximizing the potential debt to maximize yield while making sure the user doesn’t get liquidated.
This will bring TVL and users to Flow, provide a revenue stream through fees, and demonstrate a practical application of Flow’s unique feature of scheduled transactions.

## Installation
```sh
curl -L https://foundry.paradigm.xyz | bash
source ~/.zshenv   # or restart your shell
foundryup
```

## Build & Test
```bash
make ci             # fmt check + build + tests (solidity + cadence)
make solidity-test  # solidity tests only
make cadence-test   # cadence tests only (requires the Flow CLI)
```

## Architecture
See [Architecture](./docs/architecture.md)

## Deployment

Deployments are **manual** and target Flow EVM mainnet directly — see the
`mainnet-*` targets in the [`Makefile`](./Makefile) (every one has a `-dry`
variant that fork-simulates against live state first). The signer is a Foundry
encrypted keystore account; set it up once with `make setup-evm-deployer`.
Dependency addresses used at deploy time are pinned in
[`solidity/deployments/mainnet.json`](./solidity/deployments/mainnet.json).

### Deployed contracts (Flow EVM mainnet)

| Contract | Address |
| :--- | :--- |
| FCMVault | _not yet deployed_ |
| YieldTokenOracle | _not yet deployed_ |

Morpho market (WETH collateral / PYUSD0 loan, LLTV 86%):
`0xe9c0fc2a0c62a6e5cdee4bc4d06d571850a2add3bb7c96d8c3a75997cae6b866`

## Dependencies (Flow EVM mainnet)

### Morpho Blue

| Contract | Address |
| :--- | :--- |
| Morpho | [`0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f`](https://evm.flowscan.io/address/0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f?tab=contract_code) |
| Morpho IRM | [`0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546`](https://evm.flowscan.io/address/0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546?tab=contract) |

### Pyth oracles

| Feed | Address |
| :--- | :--- |
| Pyth Oracle Factory | [`0x32130316E1Fc503F8a6c8DEbA8320A9d45B3D135`](https://evm.flowscan.io/address/0x32130316E1Fc503F8a6c8DEbA8320A9d45B3D135?tab=contract) |
| WBTC/USD | [`0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8`](https://evm.flowscan.io/address/0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8?tab=read_write_contract) |
| WETH/USD | [`0xD744044044C0Dd0c73BeA440747115674Ebae030`](https://evm.flowscan.io/address/0xD744044044C0Dd0c73BeA440747115674Ebae030?tab=read_contract) |
| WFLOW/USD | [`0xd8848Ccc8beA82046Da0B144844118db17086af4`](https://evm.flowscan.io/address/0xd8848Ccc8beA82046Da0B144844118db17086af4?tab=read_write_contract) |

Update these Pyth feeds with the Foundry script. The script requires `curl`; `--ffi` lets
Foundry invoke it to fetch the latest update from Hermes. Run without `--broadcast` first to
simulate the update:

```bash
cd solidity
forge script script/UpdatePythPrices.s.sol:UpdatePythPrices \
  --rpc-url https://mainnet.evm.nodes.onflow.org \
  --account "$ACCOUNT" \
  --ffi
```

Then broadcast it:

```bash
forge script script/UpdatePythPrices.s.sol:UpdatePythPrices \
  --rpc-url https://mainnet.evm.nodes.onflow.org \
  --account "$ACCOUNT" \
  --ffi \
  --broadcast
```

Foundry prompts for the account's keystore password. Add `--sender "$SENDER"` if the sender cannot
be inferred from the account. The account must hold enough FLOW to cover the dynamic Pyth update
fee printed by the script plus gas. Per Price Feed is 0.5 FLOW. 

### ERC-20 tokens

| Token | Address |
| :--- | :--- |
| WETH | [`0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590`](https://evm.flowscan.io/address/0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590) |
| PYUSD0 | [`0x99aF3EeA856556646C98c8B9b2548Fe815240750`](https://evm.flowscan.io/address/0x99aF3EeA856556646C98c8B9b2548Fe815240750) |
| FUSDEV | [`0xd069d989e2F44B70c65347d1853C0c67e10a9F8D`](https://evm.flowscan.io/address/0xd069d989e2F44B70c65347d1853C0c67e10a9F8D) |

### FlowSwap V3 (Uniswap V3 fork)

| Contract | Address |
| :--- | :--- |
| Factory | [`0xca6d7Bb03334bBf135902e1d919a5feccb461632`](https://evm.flowscan.io/address/0xca6d7Bb03334bBf135902e1d919a5feccb461632) |
| SwapRouter02 | [`0xeEDC6Ff75e1b10B903D9013c358e446a73d35341`](https://evm.flowscan.io/address/0xeEDC6Ff75e1b10B903D9013c358e446a73d35341) |
| QuoterV2 | [`0x370A8DF17742867a44e56223EC20D82092242C85`](https://evm.flowscan.io/address/0x370A8DF17742867a44e56223EC20D82092242C85) |

Pools used by the vault (fetched via `Factory.getPool(tokenA, tokenB, fee)`):

| Pool | Fee tier |
| :--- | :--- |
| PYUSD0 / Yield token | `100` (0.01%) |
| WETH / PYUSD0 | `3000` (0.30%) |
