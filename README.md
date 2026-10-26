# DVN Operator Node

Run a Distributed Verifier Network (DVN) validator node for the Arbitrum VN.

This bundle runs three containers:

- **relay-sidecar** — the Symbiotic relay sidecar (BLS signing, p2p, valset).
- **vn-node** — the validator node that attests L2 blocks. (Validator-set headers
  are posted on-chain by Conduit each epoch — operators pay no gas for that.)
- **nitro-follower** — a read-only Nitro node that independently re-executes L2
  state so the vn-node verifies block state roots against a node you control.

Two accounts are involved, and they have different jobs:

- **Your wallet** (MetaMask, or a hardware wallet through it) **owns your stake.**
  It funds your operator once and holds the vault shares, so only it can
  withdraw. It is never imported into the node.
- **Your operator key** is your operator's on-chain identity. The dashboard
  generates it in your browser along with the node's other keys and saves it in
  `keys/keys.secret.json`. It sends the registration transactions itself, so on
  testnet you approve a single wallet transaction.

You do everything from the **DVN dashboard**: it generates your keys, gives you
this bundle with a complete `.env`, and registers your operator and your stake.
You don't edit any configuration by hand.

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
- A **wallet** (MetaMask or any injected wallet) holding a little of the parent
  chain's native token to fund your operator key: under 0.01 HYPE on HyperEVM.
  On networks with a real staking token it also needs the stake; on testnets
  the operator key mints it.
- Your own **parent-chain RPC endpoint** (e.g. a free Alchemy or QuickNode key).
  The node, relay sidecar and follower all read the parent chain continuously;
  public endpoints rate-limit and will throttle your node. You do **not** need an
  L2 RPC — the bundle runs its own Nitro follower.
- Inbound **`8880/tcp`** reachable from the internet (relay peer-to-peer).

---

## Step 1 — Become an operator in the dashboard

**Permissioned networks.** A network can require operators to be approved before
they register (an operator whitelist). If yours does and your wallet isn't
approved yet, send your **operator wallet address** to your Conduit contact and
wait for confirmation before you start; otherwise registration fails partway
through.

**Staying in the set.** Run your node continuously. An operator whose node stops
signing, or that misbehaves, can be removed from the operator set: jailed for a
period, or blacklisted. Removal doesn't slash: your stake stays in your vault,
and when the jail ends (or the blacklist is lifted) you rejoin from the dashboard
with the same vault and stake.

1. Open the DVN dashboard and connect your operator wallet.
2. Click **Become an operator** and follow the steps:
   - **Stake amount** — choose how much to stake.
   - **Keys** — the dashboard generates your operator key and your node's keys.
     Enter your parent-chain RPC URL and **download your bundle**. Nothing is
     funded or sent until you have it, so a closed tab never strands anything.
   - **Access** (permissioned networks only) — send the operator address shown
     to Conduit, then click **Check again** once you're whitelisted.
   - **Fund** — approve **one** wallet transaction that sends gas to your
     operator key.
   - **Register** — the operator key registers your keys, registers you as an
     operator, opts you into the network and your vault, and deposits your
     stake **for your wallet**. On testnets it mints the stake first; with a
     real staking token, your wallet approves and deposits it (two more
     prompts).

Your keys are generated **in your browser** and are only ever written into the
zip you download — they are never sent to Conduit or anywhere else. Keep the zip
somewhere safe. If anything is interrupted after the download, reopen the
dashboard, choose **Manage it with its keys.secret.json** and upload
`keys/keys.secret.json`: it picks up where it stopped.

The bundle contains:

- `docker-compose.yml`, `scripts/` — the node itself (this repository)
- `.env` — every setting, filled in for this network
- `keys/keys.secret.json` — your **private keys**: the operator key (`operator`), the
  node's BLS keys and its p2p identity. **Back this up and keep it secret.**
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

### Managing your operator

Open the dashboard with the wallet that owns your stake, click **Become an
operator**, choose **Manage it with its keys.secret.json** and upload
`keys/keys.secret.json`. From there you can:

- **Leave and withdraw** — the operator key opts out and unregisters; your
  wallet withdraws its stake, and claims it once the vault's withdrawal delay
  has passed (come back and upload the file again to claim). Then
  `docker compose down`.
- **Rejoin** — if you were removed from the operator set (below) and are
  allowed back, one transaction re-registers you (plus any opt-ins you dropped).
  Your keys and stake are unchanged, so a node still running with them resumes
  signing from the next epoch.

If the operator key runs low on gas for these, the dashboard asks your wallet to
top it up first.

### Removal from the operator set

Conduit can remove an operator from the set: jail it for a period, blacklist it,
or, on a permissioned network, take it off the whitelist. Removal unregisters
the operator at once and takes effect in the validator set at the next epoch.
It is not slashing: your stake stays in your vault, and your opt-ins and keys
are untouched. Nothing re-registers you
automatically: once a jail ends (or a blacklist is lifted), rejoin from the
dashboard. You can withdraw your stake at any time, removed or not.

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

| Port   | Service        | Purpose                       | Exposed on         |
| ------ | -------------- | ----------------------------- | ------------------ |
| `8880` | relay-sidecar  | libp2p (peer connectivity)    | **all interfaces** |
| `8080` | relay-sidecar  | relay API                     | `127.0.0.1` only   |
| `9090` | vn-node        | attestation + health API      | `127.0.0.1` only   |
| `8449` | nitro-follower | follower JSON-RPC             | `127.0.0.1` only   |
| `8450` | nitro-follower | follower WebSocket (newHeads) | `127.0.0.1` only   |

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
  with it controls your node's signing keys **and your operator**: they could
  change its registered keys or take it out of the set. It is git-ignored —
  never commit it.
- It **can't** move your stake: the vault shares belong to your wallet, and only
  your wallet can withdraw them.
- Your wallet's private key is never needed by, or given to, the node.
- The `.env` contains your RPC URL (which may embed a provider key) but no
  private keys.

---
