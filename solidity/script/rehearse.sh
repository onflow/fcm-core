#!/usr/bin/env bash
#
# Full deployment rehearsal against an anvil fork of Flow EVM mainnet.
#
# Runs the entire production sequence -- seed the Morpho market, deploy the
# yield oracle + FCMVault, then a real deposit/rebalance/redeem round-trip --
# against a local fork of live mainnet state, with state carried between steps.
# Real Morpho, FlowSwap, Pyth, and token contracts; zero real funds.
#
# Sequence:
#   1. start `anvil --fork-url <mainnet>` (chain id 747 is preserved, so the
#      scripts' config chain-id guard passes)
#   2. fund the anvil dev account with WETH and PYUSD0 via impersonated
#      transfers from on-chain holders (the FlowSwap pools)
#   3. if the Pyth WETH/USD market oracle is stale (it reverts with
#      StalePrice after 1h without an update), pull a fresh signed update
#      from Hermes and post it -- permissionless, same as on real mainnet
#   4. SeedMarket -> DeployVault -> LiveCheck via forge --broadcast
#   5. clean up: kill anvil and remove the rehearsal's broadcast records so
#      they can't masquerade as real chain-747 deployment records
#
# Usage (from the repo root): make mainnet-rehearse
# Knobs (all optional): FLOW_MAINNET_RPC, ANVIL_PORT, SEED_AMOUNT, MAX_TVL,
#                       CHECK_AMOUNT
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_RPC=${FLOW_MAINNET_RPC:-https://mainnet.evm.nodes.onflow.org}
ANVIL_PORT=${ANVIL_PORT:-8545}
RPC=http://127.0.0.1:${ANVIL_PORT}

# anvil's first default dev account (key is public, never holds real funds)
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Mainnet contracts (see deployments/mainnet.json and the root README)
WETH=0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590
PYUSD0=0x99aF3EeA856556646C98c8B9b2548Fe815240750
MARKET_ORACLE=0xD744044044C0Dd0c73BeA440747115674Ebae030
PYTH=0x2880aB155794e7179c9eE2e38200202908C17B43
ETH_USD_FEED=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
HERMES=https://hermes.pyth.network/v2/updates/price/latest
# Largest standing WETH / PYUSD0 holders: the FlowSwap pools themselves
WETH_WHALE=0x811491E52f828d934966BEaF21D94f14a49bF225   # WETH/PYUSD0 pool
PYUSD0_WHALE=0x9196e243b7562B0866309013f2F9EB63F83A690f # FUSDEV/PYUSD0 pool

SEED_AMOUNT=${SEED_AMOUNT:-50000000000}                  # 50k PYUSD0 (6 dec)
MAX_TVL=${MAX_TVL:-100000000000000000000}                # 100 WETH
CHECK_AMOUNT=${CHECK_AMOUNT:-10000000000000000}          # 0.01 WETH
WETH_FUND=$((CHECK_AMOUNT * 5))

log() { printf '\n=== rehearse: %s\n' "$*"; }

# Rehearsal broadcasts land in broadcast/*/747/ -- the same place as REAL
# mainnet deployment records. Refuse to run if uncommitted records are
# present (we couldn't tell them apart from ours during cleanup), and remove
# everything untracked under broadcast/ when we finish.
if [ -n "$(git status --porcelain -- broadcast 2>/dev/null)" ]; then
  echo "rehearse: uncommitted files under solidity/broadcast/ -- commit or remove them first" >&2
  exit 1
fi

ANVIL_PID=
ANVIL_LOG=$(mktemp -t fcm-rehearse-anvil)
cleanup() {
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
  git clean -qfd -- broadcast 2>/dev/null || true
  git checkout -q -- broadcast 2>/dev/null || true
}
trap cleanup EXIT

log "starting anvil fork of $FORK_RPC (log: $ANVIL_LOG)"
anvil --fork-url "$FORK_RPC" --port "$ANVIL_PORT" --auto-impersonate --silent \
  >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN_ID" = 747 ] || { echo "rehearse: fork chain id $CHAIN_ID != 747" >&2; exit 1; }

log "funding $ADDR with WETH and PYUSD0 from on-chain holders"
GAS=0xde0b6b3a7640000 # 1 FLOW for the impersonated holders' gas
cast rpc anvil_setBalance "$WETH_WHALE" "$GAS" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$PYUSD0_WHALE" "$GAS" --rpc-url "$RPC" >/dev/null
cast send "$WETH" "transfer(address,uint256)" "$ADDR" "$WETH_FUND" \
  --from "$WETH_WHALE" --unlocked --rpc-url "$RPC" >/dev/null
cast send "$PYUSD0" "transfer(address,uint256)" "$ADDR" "$SEED_AMOUNT" \
  --from "$PYUSD0_WHALE" --unlocked --rpc-url "$RPC" >/dev/null

if ! cast call "$MARKET_ORACLE" "price()(uint256)" --rpc-url "$RPC" >/dev/null 2>&1; then
  log "market oracle is stale; posting a fresh Pyth update from Hermes"
  UPDATE=0x$(curl -sf "$HERMES?ids[]=$ETH_USD_FEED&encoding=hex" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["binary"]["data"][0])')
  FEE=$(cast call "$PYTH" "getUpdateFee(bytes[])(uint256)" "[$UPDATE]" --rpc-url "$RPC")
  cast send "$PYTH" "updatePriceFeeds(bytes[])" "[$UPDATE]" \
    --value "${FEE%% *}" --private-key "$KEY" --rpc-url "$RPC" >/dev/null
  cast call "$MARKET_ORACLE" "price()(uint256)" --rpc-url "$RPC" >/dev/null ||
    { echo "rehearse: market oracle still reverting after Pyth update" >&2; exit 1; }
fi

log "SeedMarket: supplying $SEED_AMOUNT PYUSD0 to the Morpho market"
SEED_AMOUNT=$SEED_AMOUNT forge script script/SeedMarket.s.sol \
  --rpc-url "$RPC" --broadcast --private-key "$KEY"

log "DeployVault: yield oracle + FCMVault + admin setup"
DEPLOY_LOG=$(mktemp -t fcm-rehearse-deploy)
MAX_TVL=$MAX_TVL forge script script/DeployVault.s.sol \
  --rpc-url "$RPC" --broadcast --private-key "$KEY" | tee "$DEPLOY_LOG"
VAULT=$(grep -E 'FCMVault: +0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | grep -oE '0x[0-9a-fA-F]{40}')
[ -n "$VAULT" ] || { echo "rehearse: could not parse FCMVault address from deploy output" >&2; exit 1; }

log "LiveCheck: deposit/rebalance/redeem round-trip against $VAULT"
VAULT=$VAULT CHECK_AMOUNT=$CHECK_AMOUNT forge script script/LiveCheck.s.sol \
  --rpc-url "$RPC" --broadcast --private-key "$KEY"

log "PASSED -- full deployment sequence works against current mainnet state"
