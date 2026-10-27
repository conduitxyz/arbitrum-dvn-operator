#!/bin/sh
set -e

# Starts the VN validator node. Waits for the relay sidecar to come up.
#
# Args: $1 = relay API URL (default http://relay-sidecar:8080/api/v1)

RELAY_API_URL="${1:-http://relay-sidecar:8080/api/v1}"
L1_RPC="${L1_RPC:?set L1_RPC in .env}"
# The node reads L2 from its co-located follower (not the shared sequencer RPC).

echo "Waiting for keys/network.env ..."
until [ -f /keys/network.env ]; do
    echo "  keys/network.env not found — download your operator bundle from the DVN dashboard"
    sleep 3
done
. /keys/network.env

# AddressRegistry — the node resolves the ValSetDriver (epoch schedule), the
# Settlement (committed-header epoch), and the SequencerInboxVN (batch-resume
# anchor) from this single address.
: "${ADDRESS_REGISTRY:?ADDRESS_REGISTRY missing from .env}"

DB_FLAG=""
if [ -d /data ] && [ -w /data ]; then
    DB_FLAG="--db-path /data/attestations.db"
    echo "Using SQLite attestation DB at /data/attestations.db"
else
    echo "WARNING: /data not writable, using in-memory store (attestations lost on restart)"
fi

# Batch-pull client: connect to Conduit's proxy to receive batches to co-sign.
# The node authenticates with its header BLS key (bls_${HEADER_KEY_TAG}) from the
# secret store in /keys (keys.secret.json) — the same key registered on-chain to the
# operator. No extra key or cert is needed.
PULL_FLAGS=""
if [ -n "${PROXY_PULL_URL:-}" ]; then
    : "${OPERATOR_ADDRESS:?OPERATOR_ADDRESS required when PROXY_PULL_URL is set}"
    : "${HEADER_KEY_TAG:?HEADER_KEY_TAG missing from keys/network.env — re-download your bundle from the DVN dashboard}"
    PULL_FLAGS="--proxy-pull-url ${PROXY_PULL_URL} --operator-address ${OPERATOR_ADDRESS} --keys-dir /keys --header-key-tag ${HEADER_KEY_TAG}"
    # Transport security auto-detects from the URL (TLS iff :443 or grpcs://).
    # Set PROXY_PULL_TLS=true|false only to override.
    [ -n "${PROXY_PULL_TLS:-}" ] && PULL_FLAGS="${PULL_FLAGS} --proxy-pull-tls ${PROXY_PULL_TLS}"
fi

# STF: the node reads L2 from its co-located Nitro follower, which independently
# re-executes ArbOS; its post-state root is signed into every attestation.
FEED_FLAG=""
[ -n "${FOLLOWER_FEED_URL:-}" ] && FEED_FLAG="--sequencer-feed-url ${FOLLOWER_FEED_URL}"

FOLLOWER_RPC_URL="${FOLLOWER_RPC_URL:-http://nitro-follower:8449}"
# WebSocket on the same follower, used only for the newHeads subscription so
# block pickup tracks block production instead of the poll interval. If it is
# unreachable the node falls back to polling, so this is not load-bearing.
FOLLOWER_WS_URL="${FOLLOWER_WS_URL:-ws://nitro-follower:8450}"
echo "STF: reading L2 from co-located follower ${FOLLOWER_RPC_URL} (newHeads via ${FOLLOWER_WS_URL})"

RELAY_HOST=$(echo "$RELAY_API_URL" | sed -E 's|https?://([^:/]+).*|\1|')
RELAY_PORT=$(echo "$RELAY_API_URL" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
RELAY_PORT=${RELAY_PORT:-8080}

echo "Waiting for relay sidecar at $RELAY_HOST:$RELAY_PORT ..."
i=0
while [ $i -lt 60 ]; do
    if wget -q --spider "http://$RELAY_HOST:$RELAY_PORT/" 2>/dev/null; then
        echo "Relay sidecar ready!"
        break
    fi
    i=$((i + 1))
    sleep 2
done

exec /app/vn-node \
    --follower-rpc-url "$FOLLOWER_RPC_URL" \
    --follower-ws-url "$FOLLOWER_WS_URL" \
    --l1-rpc-url "$L1_RPC" \
    --relay-api-url "$RELAY_API_URL" \
    --http-addr ":9090" \
    --address-registry-addr "$ADDRESS_REGISTRY" \
    $DB_FLAG \
    $PULL_FLAGS \
    $FEED_FLAG \
    --log-level "${LOG_LEVEL:-info}"
