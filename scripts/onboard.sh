#!/bin/sh
set -e

# One-time onboarding: generate the node's keys, read the required key tags from
# chain, and emit ./keys/registration-payload.json for the dashboard plus
# ./keys/secret-keys.txt and ./keys/network.env for the sidecar/node.

: "${OPERATOR_ADDRESS:?set OPERATOR_ADDRESS in .env}"
: "${ADDRESS_REGISTRY:?set ADDRESS_REGISTRY in .env}"
: "${L1_RPC:?set L1_RPC in .env}"

exec /app/vn-node onboard \
    --operator "$OPERATOR_ADDRESS" \
    --address-registry "$ADDRESS_REGISTRY" \
    --l1-rpc-url "$L1_RPC" \
    --keys-dir /keys \
    --log-level "${LOG_LEVEL:-info}"
