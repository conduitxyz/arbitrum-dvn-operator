# DVN Operator Node

Run a Distributed Verifier Network (DVN) validator node for the Arbitrum VN.

This bundle runs three containers:

- **relay-sidecar** — the Symbiotic relay sidecar (BLS signing, p2p, valset).
- **vn-node** — the validator node that attests L2 blocks. (Validator-set headers
  are posted on-chain by Conduit each epoch — operators pay no gas for that.)
- **nitro-follower** — a read-only Nitro node that independently re-executes L2
  state so the vn-node verifies block state roots against a node you control.

Your **operator wallet (MetaMask)** is your on-chain identity and holds your
stake. It is **never** imported into the node: the node has its own keys, bound
to your wallet address by signed proofs.

You do everything from the **DVN dashboard**: it generates your node's keys,
registers them and your stake from your wallet, and downloads this bundle with a
complete `.env` and your keys. You don't edit any configuration by hand.

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
  Images are published for `linux/amd64` and `linux/arm64`.
- An **operator wallet** (MetaMask or any injected wallet) holding the native
  token for gas and the staking token. On testnets the dashboard can mint the
  staking token for you.
- Your own **parent-chain RPC endpoint** (e.g. a free Alchemy or QuickNode key).
  The node, relay sidecar and follower all read the parent chain continuously;
  public endpoints rate-limit and will throttle your node. You do **not** need an
  L2 RPC — the bundle runs its own Nitro follower.
- Inbound **`8880/tcp`** reachable from the internet (relay peer-to-peer).

---

## Step 1 — Become an operator in the dashboard

1. Open the DVN dashboard and connect your operator wallet.
2. Click **Become an operator** and follow the steps:
   - **Sign** one message proving your wallet owns the node's new keys (no gas).
   - **Stake amount** — choose how much to stake (on testnets, mint it here).
   - **Register** — approve the transactions that register your keys, register
     you as an operator, opt you into the network and your vault, and deposit
     your stake.
   - **Download** — enter your parent-chain RPC URL and download your bundle.

Your node's keys are generated **in your browser** and are only ever written into
the zip you download — they are never sent to Conduit or anywhere else. Keep the
zip somewhere safe.

The bundle contains:

- `docker-compose.yml`, `scripts/` — the node itself (this repository)
- `.env` — every setting, filled in for this network
- `keys/keys.secret.json` — your node's **private keys**. **Back this up and keep it secret.**
- `keys/secret-keys.txt`, `keys/network.env` — derived from the above; read by the node

---

## Step 2 — Run the node

```bash
unzip dvn-operator-*.zip
cd dvn-operator-*/
docker compose up -d
```

Check status:

```bash
docker compose logs -f
curl -s localhost:9090/health
```

The follower first syncs the L2 chain, which can take a while on a long-lived
chain. Your stake joins the validator set at the **next epoch boundary**, so your
node starts signing up to one epoch after you register; the dashboard shows you
as an operator from then on.

To stop:

```bash
docker compose down
```

To stop being an operator, use **Leave as operator** in the dashboard (it
unregisters you and starts the stake withdrawal), then `docker compose down`.

---

## STF (state-transition) verification

The bundle always runs a **co-located Nitro follower** that feed-follows the chain
and independently re-executes ArbOS. The node reads L2 from that follower (a node
_you_ control) and signs its post-state root into every attestation, so a quorum
becomes a proof that the operators agree on the computed state — not just on what
the sequencer reported. This is on by default; `docker compose up -d` starts it.

The `FOLLOWER_*` values (feed URL, chainInfo URL, DA mode and endpoint) come
filled in from the dashboard. If the parent chain has blobs (Ethereum, Sepolia),
the follower also needs a parent-chain beacon endpoint (`L1_BEACON_URL`); the
dashboard asks for it when it applies. HyperEVM has no blobs, so none is needed
there.

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

| Port   | Service        | Purpose                                | Exposed on      |
| ------ | -------------- | -------------------------------------- | --------------- |
| `8880` | relay-sidecar  | libp2p (peer connectivity)             | **all interfaces** |
| `8080` | relay-sidecar  | relay API                              | `127.0.0.1` only |
| `9090` | vn-node        | attestation + health API               | `127.0.0.1` only |
| `8449` | nitro-follower | follower JSON-RPC                      | `127.0.0.1` only |
| `8450` | nitro-follower | follower WebSocket (newHeads)          | `127.0.0.1` only |

Only `8880/tcp` needs to be reachable from outside; open it if you are behind
NAT or a firewall, or the node may struggle to join the relay network.

**Keep the others on `127.0.0.1`.** The relay API signs any message it is sent
with your node's BLS key — it has no authentication — so anyone who can reach
`8080` can make your node sign things you never verified. Docker publishes ports
around host firewalls such as `ufw`, so the bind address in `docker-compose.yml`
is what keeps these private. To serve the attestation API to other machines, put
an authenticated or GET-only reverse proxy in front of `127.0.0.1:9090` rather
than publishing the port.

---

## Upgrading

When the DVN announces a new release, bump `VN_NODE_TAG` (and `RELAY_TAG` if it
changes) in `.env` and update `docker-compose.yml` and `scripts/` from this
repository at the same tag, then:

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
(~3.5 KB per L2 block), bounded separately by `RELAY_DATA_RETENTION_EPOCHS`. The dashboard sets it to about
one day's worth for the network's epoch length, e.g. `24` at 1-hour epochs.

---

## Security notes

- `./keys/keys.secret.json` holds your private keys. Back it up securely; anyone
  with it controls your node's signing keys. It is git-ignored — never commit it.
- Your operator wallet's private key is never needed by, or given to, the node.
- The `.env` contains your RPC URL (which may embed a provider key) but no
  private keys.

---
