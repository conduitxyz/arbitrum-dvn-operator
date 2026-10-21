#!/bin/sh
set -e

# Starts a co-located Nitro follower for STF (state-transition) verification.
#
# The follower feed-follows the chain and independently re-executes ArbOS so the
# vn-node can read L2 state roots from a node it controls (instead of trusting
# the shared sequencer RPC). It is read-only: no sequencing, batch-posting or
# staking. Enabled only when the 'stf' compose profile is active.
#
# Required env (.env):
#   L1_RPC                  parent-chain execution RPC
#   FOLLOWER_BEACON_URL     parent-chain beacon/consensus endpoint. REQUIRED when
#                           the parent chain supports 4844 (the default); Nitro
#                           reads blob batches through it. Defaults from
#                           L1_BEACON_URL. Not needed when
#                           PARENT_CHAIN_HAS_BLOBS=false.
#   FOLLOWER_FEED_URL       sequencer/relay feed (ws://...:9642)
# Optional:
#   PARENT_CHAIN_HAS_BLOBS  true (default) | false. Set false when the parent chain
#                           has no beacon layer (e.g. HyperEVM): the follower then
#                           runs with --node.dangerous.disable-blob-reader and no
#                           beacon URL. Without it Nitro fatals at boot with
#                           "a beacon chain RPC URL is required to read batches".
#   FOLLOWER_DA_MODE        anytrust | blob | calldata   (default calldata)
#   FOLLOWER_DAS_URL        AnyTrust REST aggregator URL  (anytrust)
#   FOLLOWER_DAS_ONLINE_URL AnyTrust online-url-list      (anytrust)
#
# chainInfo.json is fetched + unwrapped into /config by the nitro-follower-init
# service (alpine + jq) BEFORE this container starts, so we don't depend on the
# Nitro image shipping jq. We just wait for the file and use it.

L1_RPC="${L1_RPC:?set L1_RPC in .env}"
FOLLOWER_FEED_URL="${FOLLOWER_FEED_URL:?set FOLLOWER_FEED_URL in .env}"
# Parent-chain blob capability. On a 4844-capable parent the follower needs a
# beacon URL; on a parent with no beacon layer it must disable the blob reader.
PARENT_CHAIN_HAS_BLOBS="${PARENT_CHAIN_HAS_BLOBS:-true}"
case "$PARENT_CHAIN_HAS_BLOBS" in
    true|false) ;;
    *) echo "[follower] PARENT_CHAIN_HAS_BLOBS must be 'true' or 'false' (got '$PARENT_CHAIN_HAS_BLOBS')"; exit 1 ;;
esac
FOLLOWER_BEACON_URL="${FOLLOWER_BEACON_URL:-${L1_BEACON_URL:-}}"
if [ "$PARENT_CHAIN_HAS_BLOBS" = true ]; then
    : "${FOLLOWER_BEACON_URL:?set L1_BEACON_URL (or FOLLOWER_BEACON_URL) — the parent-chain beacon endpoint the follower reads blob batches from. Set PARENT_CHAIN_HAS_BLOBS=false if this parent chain has no beacon layer (e.g. HyperEVM)}"
else
    [ -z "$FOLLOWER_BEACON_URL" ] || echo "[follower] PARENT_CHAIN_HAS_BLOBS=false — ignoring the configured beacon URL."
    FOLLOWER_BEACON_URL=""
fi
FOLLOWER_DA_MODE="${FOLLOWER_DA_MODE:-calldata}"

CHAIN_INFO=/config/chainInfo.json
# The init service writes this before we start (compose service_completed_successfully),
# but wait defensively in case of manual/unordered starts.
i=0
while [ ! -s "$CHAIN_INFO" ]; do
    i=$((i + 1)); [ "$i" -ge 30 ] && { echo "[follower] chainInfo.json missing at $CHAIN_INFO (is nitro-follower-init healthy?)"; exit 1; }
    echo "[follower] waiting for chainInfo.json ($i/30)…"; sleep 2
done
case "$(head -c1 "$CHAIN_INFO")" in
    "[") : ;;
    *) echo "[follower] ERROR: $CHAIN_INFO is not a JSON array (init unwrap failed)"; exit 1 ;;
esac

if [ "$PARENT_CHAIN_HAS_BLOBS" = false ]; then
    DA_FLAGS="--node.dangerous.disable-blob-reader"
else
    DA_FLAGS="--parent-chain.blob-client.beacon-url=${FOLLOWER_BEACON_URL}"
fi
if [ "$FOLLOWER_DA_MODE" = "anytrust" ]; then
    : "${FOLLOWER_DAS_URL:?FOLLOWER_DAS_URL required when FOLLOWER_DA_MODE=anytrust}"
    DA_FLAGS="$DA_FLAGS --node.da.anytrust.enable=true --node.da.anytrust.rest-aggregator.enable=true --node.da.anytrust.rest-aggregator.urls=${FOLLOWER_DAS_URL} --node.da.anytrust.rpc-aggregator.enable=false"
    [ -n "${FOLLOWER_DAS_ONLINE_URL:-}" ] && DA_FLAGS="$DA_FLAGS --node.da.anytrust.rest-aggregator.online-url-list=${FOLLOWER_DAS_ONLINE_URL}"
    # DAS readiness: Nitro fatals fast if the DAS endpoints aren't reachable at
    # boot. Wait (bounded) so a briefly-unavailable DAS doesn't crash-loop the node.
    for u in "$FOLLOWER_DAS_URL" "${FOLLOWER_DAS_ONLINE_URL:-}"; do
        [ -n "$u" ] || continue
        i=0
        while [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u" 2>/dev/null)" = "000" ]; do
            i=$((i + 1)); [ "$i" -ge 60 ] && { echo "[follower] DAS $u unreachable after 60 tries; starting anyway"; break; }
            echo "[follower] waiting for DAS $u ($i/60)"; sleep 2
        done
    done
fi

echo "[follower] feed=$FOLLOWER_FEED_URL da=$FOLLOWER_DA_MODE parentBlobs=$PARENT_CHAIN_HAS_BLOBS beacon=${FOLLOWER_BEACON_URL:-<none>}"
exec /usr/local/bin/nitro \
    --chain.info-files "$CHAIN_INFO" \
    --parent-chain.connection.url "$L1_RPC" \
    --node.sequencer=false \
    --execution.sequencer.enable=false \
    --execution.forwarding-target=null \
    --node.delayed-sequencer.enable=false \
    --node.staker.enable=false \
    --node.batch-poster.enable=false \
    --node.feed.input.url "$FOLLOWER_FEED_URL" \
    --http.addr 0.0.0.0 \
    --http.port 8449 \
    --http.api net,web3,eth,arb \
    --http.corsdomain '*' \
    --http.vhosts '*' \
    --ws.addr 0.0.0.0 \
    --ws.port 8450 \
    --ws.origins '*' \
    --ensure-rollup-deployment=false \
    $DA_FLAGS
