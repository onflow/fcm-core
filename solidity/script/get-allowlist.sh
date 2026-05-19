#!/usr/bin/env bash
#
# get-allowlist.sh
#
# Print the current set of allowed addresses on an Allowlist contract by
# replaying its AddressAllowed / AddressDisallowed events.
#
# The Allowlist contract is intentionally not enumerable on-chain. Off-chain
# consumers reconstruct the set from event logs — that's what this script does.
#
# Requires: cast (from foundry), jq, awk, sort.

set -euo pipefail

DEFAULT_RPC_URL="https://mainnet.evm.nodes.onflow.org"

usage() {
    cat <<EOF
Usage: get-allowlist.sh --address <allowlist> [options]

Required:
  --address <addr>      Allowlist contract address

Options:
  --rpc-url <url>       JSON-RPC endpoint (default: ${DEFAULT_RPC_URL})
  --from-block <n>      Start block (default: contract deployment block)
  --to-block <n>        End block (default: latest)
  --json                Emit a JSON array (default: one address per line)
  -h, --help            Show this help

Examples:
  get-allowlist.sh --address 0xABC...
  get-allowlist.sh --address 0xABC... --json
  get-allowlist.sh --address 0xABC... --rpc-url https://testnet.evm.nodes.onflow.org
EOF
}

ADDRESS=""
RPC_URL="$DEFAULT_RPC_URL"
FROM_BLOCK=""
TO_BLOCK="latest"
JSON_OUTPUT="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --address)    ADDRESS="$2";       shift 2 ;;
        --rpc-url)    RPC_URL="$2";       shift 2 ;;
        --from-block) FROM_BLOCK="$2";    shift 2 ;;
        --to-block)   TO_BLOCK="$2";      shift 2 ;;
        --json)       JSON_OUTPUT="true"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$ADDRESS" ]]; then
    echo "Error: --address is required" >&2
    usage >&2
    exit 1
fi

for cmd in cast jq awk sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# Binary-search for the smallest block N where eth_getCode(addr, N) != "0x".
# That's the deployment block. Assumes code monotonicity (no SELFDESTRUCT).
find_deploy_block() {
    local addr="$1"
    local rpc="$2"
    local latest lo hi mid code

    latest=$(cast block-number --rpc-url "$rpc")
    code=$(cast code "$addr" --block "$latest" --rpc-url "$rpc")
    if [[ "$code" == "0x" || -z "$code" ]]; then
        echo "Error: no contract code at $addr (checked block $latest)" >&2
        return 1
    fi

    lo=0
    hi="$latest"
    while (( lo < hi )); do
        mid=$(( (lo + hi) / 2 ))
        code=$(cast code "$addr" --block "$mid" --rpc-url "$rpc")
        if [[ "$code" == "0x" || -z "$code" ]]; then
            lo=$(( mid + 1 ))
        else
            hi=$mid
        fi
    done

    echo "$lo"
}

if [[ -z "$FROM_BLOCK" ]]; then
    FROM_BLOCK=$(find_deploy_block "$ADDRESS" "$RPC_URL")
    echo "[info] auto-detected deployment block: $FROM_BLOCK" >&2
fi

# Fetch logs for one event signature and emit tab-separated records:
#   <blockNumber>\t<logIndex>\t<label>\t<address>
# blockNumber and logIndex may be hex (0x...) or decimal depending on cast version;
# both forms are normalized later.
fetch_events() {
    local event_sig="$1"
    local label="$2"
    cast logs \
        --address "$ADDRESS" \
        --rpc-url "$RPC_URL" \
        --from-block "$FROM_BLOCK" \
        --to-block "$TO_BLOCK" \
        --json \
        "$event_sig" \
        | jq -r --arg label "$label" '
            .[] | [
                .blockNumber,
                .logIndex,
                $label,
                ("0x" + (.topics[1] | .[26:]))
            ] | @tsv'
}

ALLOWED_LOGS=$(fetch_events "AddressAllowed(address)" "allow")
DISALLOWED_LOGS=$(fetch_events "AddressDisallowed(address)" "disallow")

# Two-pass awk: (1) normalize block/logIndex to zero-padded decimals so a
# lexicographic sort yields chronological order; (2) replay events to compute
# the current set, with the last event per address winning.
RESULT=$(
    { printf '%s\n' "$ALLOWED_LOGS"; printf '%s\n' "$DISALLOWED_LOGS"; } \
        | awk -F'\t' '
            function hex2dec(s,    n,c,i,r) {
                sub(/^0x/, "", s)
                if (s == "") return 0
                r = 0
                for (i = 1; i <= length(s); i++) {
                    c = tolower(substr(s, i, 1))
                    n = (c ~ /[0-9]/) ? c + 0 : index("abcdef", c) + 9
                    r = r * 16 + n
                }
                return r
            }
            NF == 4 {
                bn = $1; li = $2
                if (bn ~ /^0[xX]/) bn = hex2dec(bn)
                if (li ~ /^0[xX]/) li = hex2dec(li)
                printf "%020d\t%020d\t%s\t%s\n", bn, li, $3, tolower($4)
            }
        ' \
        | sort \
        | awk -F'\t' '
            $3 == "allow"    { active[$4] = 1 }
            $3 == "disallow" { delete active[$4] }
            END {
                n = 0
                for (a in active) result[n++] = a
                # Insertion sort — small N (admin-managed lists, not millions).
                for (i = 1; i < n; i++) {
                    key = result[i]; j = i - 1
                    while (j >= 0 && result[j] > key) {
                        result[j+1] = result[j]; j--
                    }
                    result[j+1] = key
                }
                for (i = 0; i < n; i++) print result[i]
            }
        '
)

if [[ "$JSON_OUTPUT" == "true" ]]; then
    if [[ -z "$RESULT" ]]; then
        echo "[]"
    else
        printf '%s\n' "$RESULT" | jq -R -s 'split("\n") | map(select(length > 0))'
    fi
else
    if [[ -n "$RESULT" ]]; then
        printf '%s\n' "$RESULT"
    fi
fi
