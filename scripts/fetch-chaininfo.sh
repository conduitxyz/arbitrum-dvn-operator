#!/bin/sh
set -e

# One-shot init: fetch this chain's chainInfo.json and write it to the shared
# /config volume for the Nitro follower. Runs in a small alpine image (with curl +
# jq) so it never depends on the Nitro image shipping jq.
#
# The Conduit observer endpoint returns a WRAPPER:
#   {"chain":{"info-json":"[{...}]"}}
# but Nitro's --chain.info-files wants the raw array [{...}], so we unwrap
# .chain["info-json"] here (falling back to the body as-is if it's already an array).
#
# Required env:
#   FOLLOWER_CHAIN_INFO_URL  URL to fetch chainInfo from (the DVN publishes this)

FOLLOWER_CHAIN_INFO_URL="${FOLLOWER_CHAIN_INFO_URL:?set FOLLOWER_CHAIN_INFO_URL in .env}"
OUT=/config/chainInfo.json
RAW=/config/raw.json

command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null
command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null

echo "[chaininfo] fetching from ${FOLLOWER_CHAIN_INFO_URL}"
i=0
until curl -fsS "${FOLLOWER_CHAIN_INFO_URL}" -o "$RAW"; do
    i=$((i + 1)); [ "$i" -ge 30 ] && { echo "[chaininfo] failed to fetch after 30 tries"; exit 1; }
    echo "  retry $i/30"; sleep 2
done

# Unwrap the observer wrapper if present; otherwise use the body as-is.
UNWRAPPED=/config/unwrapped.json
if jq -e '.chain["info-json"]' "$RAW" >/dev/null 2>&1; then
    jq -r '.chain["info-json"]' "$RAW" > "$UNWRAPPED"
else
    cp "$RAW" "$UNWRAPPED"
fi

# Sanity: Nitro needs a JSON array.
case "$(head -c1 "$UNWRAPPED")" in
    "[") : ;;
    *) echo "[chaininfo] ERROR: chainInfo.json is not a JSON array (unexpected format)"; exit 1 ;;
esac

# The parent chain is L1 (not Arbitrum); set parent-chain-is-arbitrum explicitly to
# silence Nitro's "field is missing" warning (and future-proof — it becomes required).
jq 'map(. + {"parent-chain-is-arbitrum": false})' "$UNWRAPPED" > "$OUT"
echo "[chaininfo] chainInfo.json ready at $OUT"
