# DVN Operator Node

Run a Distributed Verifier Network (DVN) validator node for the Arbitrum VN.

This bundle runs three containers:

- **relay-sidecar** — the Symbiotic relay sidecar (BLS signing, p2p, valset).
- **vn-node** — the validator node that attests L2 blocks. (Validator-set headers
  are posted on-chain by Conduit each epoch — operators pay no gas for that.)
- **nitro-follower** — a read-only Nitro node that independently re-executes L2
  state so the vn-node verifies block state roots against a node you control.

Your **operator wallet (MetaMask)** is your on-chain identity and holds your
stake. It is **never** imported into the node — the node generates its own keys
and binds them to your wallet address via signed proofs. You register those keys
and stake from your wallet in the DVN dashboard.

---

## Prerequisites

- **Hardware** (a single host running all containers):

  | Resource | Minimum             | Recommended |
  | -------- | ------------------- | ----------- |
  | CPU      | 2 vCPU              | 4 vCPU      |
  | Memory   | 4 GB                | 8 GB        |
  | Disk     | 100 GB SSD          | 200 GB SSD  |
  | Network  | Reliable, unmetered | —           |

  Most of this is the **Nitro follower** (`nitro-follower`), which independently
  re-executes ArbOS from the feed — it is CPU-bursty during sync/catch-up and holds
  the chain state on disk (grows with the chain). Undersized hosts are the most
  common cause of a node that "won't start" or falls behind: a CPU-starved follower
  can't complete its L1 TLS handshake and crash-loops, taking the vn-node with it.
  SSD (not HDD) is required for acceptable follower sync. Sizing will vary with
  chain age/throughput — start here and scale up if the follower lags.

- **Docker** with **Compose v2** (`docker compose`, not `docker-compose`).
- An **operator wallet** with the required amount of the staking token.
- The **network parameters** published by the DVN operator:
  - `ADDRESS_REGISTRY` (one contract address; everything else is resolved from it)
  - an `L1_RPC` (parent-chain) endpoint — you do **not** need an L2 RPC; the
    bundle runs its own Nitro follower and the node reads L2 only from that
  - `BOOTNODE` multiaddr
  - the image tag (`VN_NODE_TAG`) to run

---

## Step 1 — Configure

```bash
cp .env.example .env
```

Edit `.env` and fill in every value. At minimum:

| Variable           | What it is                                                                                                              |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `OPERATOR_ADDRESS` | Your operator wallet address (keys bind to this; holds the stake)                                                       |
| `ADDRESS_REGISTRY` | The DVN's on-chain AddressRegistry                                                                                      |
| `L1_RPC`           | Your parent-chain (L1) RPC endpoint. No L2 RPC is needed — the bundle's own Nitro follower is the node's only L2 source |
| `BOOTNODE`         | libp2p bootnode multiaddr to join the relay network                                                                     |
| `VN_NODE_TAG`      | The exact release tag the DVN told you to run (do **not** use `latest`)                                                 |

---

## Step 2 — Onboard (generate keys + registration payload)

```bash
docker compose run --rm onboard
```

This generates your keys and writes them to `./keys/`:

- `keys.secret.json` — your **private keys** (BLS, p2p). **Back this up and keep it secret.**
- `secret-keys.txt`, `network.env` — consumed by the node; no action needed.
- `registration-payload.json` — the **public** payload you give to the dashboard.

Re-running `onboard` is safe — it reuses existing keys. (Validator-set headers are
posted on-chain by Conduit each epoch, so operators pay no gas for them.)

---

## Step 3 — Register + stake in the dashboard

1. Open the DVN dashboard and connect the **same wallet** as `OPERATOR_ADDRESS`.
2. Upload `./keys/registration-payload.json`.
3. Approve the key-registration transactions and stake — all signed from your
   wallet. (The dashboard will refuse if the connected wallet doesn't match the
   payload's operator address.)

---

## Step 4 — Run the node

```bash
docker compose up -d
```

Check status:

```bash
docker compose logs -f
curl -s localhost:9090/health
```

To stop:

```bash
docker compose down
```

---

## STF (state-transition) verification

The bundle always runs a **co-located Nitro follower** that feed-follows the chain
and independently re-executes ArbOS. The node reads L2 from that follower (a node
_you_ control) and signs its post-state root into every attestation, so a quorum
becomes a proof that the operators agree on the computed state — not just on what
the sequencer reported. This is on by default; `docker compose up -d` starts it.

You must set the `FOLLOWER_*` values published by the DVN (feed URL, chainInfo URL,
DA mode + DA endpoint for your chain's mode) and `L1_BEACON_URL` — the follower
reads L2 batches from L1, so it needs an L1 beacon (consensus-layer) endpoint in
every DA mode (same class of dependency as `L1_RPC`).

How it fits together:

- A one-shot `nitro-follower-init` container runs first: it fetches this chain's
  `chainInfo.json` from `FOLLOWER_CHAIN_INFO_URL` and unwraps it into a shared
  volume (a small `alpine`+`jq` image, so it doesn't depend on the Nitro image
  shipping jq). The follower waits for it via `service_completed_successfully`.
- The follower exposes JSON-RPC on `8449` and has a healthcheck (its RPC answering
  `eth_chainId`). The `vn-node` waits for the follower to be healthy
  (`depends_on: service_healthy`) before starting, so it never crash-restarts while
  the follower boots. The node dials `http://nitro-follower:8449` for L2.
- The follower's first sync re-executes history from the feed and can take a while
  depending on chain size.

---

## Ports

| Port   | Service        | Purpose                        |
| ------ | -------------- | ------------------------------ |
| `8080` | relay-sidecar  | relay API                      |
| `8880` | relay-sidecar  | libp2p (peer connectivity)     |
| `9090` | vn-node        | health + batch-verifier API    |
| `8449` | nitro-follower | follower JSON-RPC (co-located) |

If your node runs behind NAT/a firewall, make sure inbound `8880/tcp` is
reachable so peers can connect; otherwise the node may struggle to join the
relay network.

---

## Upgrading

Bump `VN_NODE_TAG` (and `RELAY_TAG` if the DVN changes it) in `.env`, then:

```bash
docker compose pull
docker compose up -d
```

Your keys in `./keys/` are preserved across upgrades.

### Relay sidecar sync time

The relay sidecar keeps a rolling window of recent epochs (`RELAY_RETENTION_EPOCHS`, default 144).
On a **fresh** data volume it starts from the recent past rather than replaying the network's entire
history, so joining an established network takes minutes instead of hours.

This start-point optimisation only applies to an empty volume. A sidecar that already synced from
genesis keeps its history and just begins pruning. To reclaim that space and get the fast start:

```bash
docker compose down -v      # deletes the sidecar volume — keys in ./keys/ are NOT affected
docker compose up -d
```

Set `RELAY_RETENTION_EPOCHS=0` to keep full history instead (archive node). It cannot go below
**144**: the node signs attestations that can reference epochs up to 120 back, and if the sidecar
had pruned one, those signatures would never produce a proof — so the sidecar refuses to start.

That value only governs validator sets, which are tiny. Disk usage comes from proofs and signatures
(~3.5 KB per L2 block), bounded separately by `RELAY_DATA_RETENTION_EPOCHS`. Leave it empty unless
the DVN gives you a value; on networks with long epochs it will typically be lower, e.g. `24` at
1-hour epochs for one day of proofs.

---

## Security notes

- `./keys/keys.secret.json` holds your private keys. Back it up securely; anyone
  with it controls your node's signing keys. It is git-ignored — never commit it.
- Your operator wallet's private key is never needed by, or given to, the node.
- The `registration-payload.json` contains **no secrets** and is safe to upload.

---
