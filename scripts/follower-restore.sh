#!/bin/sh
# One-shot init: on an empty follower volume, restore the chain database from a
# snapshot, so the follower catches up from the snapshot's block instead of
# re-executing the chain from genesis (days to weeks on a long-running chain).
#
# FOLLOWER_SNAPSHOT_URL is an https URL to a tar of a Nitro node's data directory
# (l2chaindata/, arbitrumdata/, ... at its root), e.g. a signed URL to the DVN's
# daily full-node snapshot. It's streamed straight into the volume (curl | tar -x),
# so it needs only the snapshot's size in free disk, not twice that.
#
# Runs on every `docker compose up` (compose restarts one-shot services), and does
# nothing when the volume already holds a database: the URL is only used for an
# empty volume, so an expired signed URL left in .env does no harm. A restore that
# was interrupted (the container stopped, the download failed) is wiped and started
# over on the next run.
#
# Env:
#   FOLLOWER_SNAPSHOT_URL           the snapshot (empty: sync from genesis)
#   FOLLOWER_SNAPSHOT_STATE_SCHEME  the snapshot's state scheme (default path, the
#                                   DVN's snapshots); the follower starts with it
#   FOLLOWER_SNAPSHOT_ATTEMPTS      downloads to try before giving up (default 3)
#   FOLLOWER_UID                    the Nitro image's user (default 1000)
set -eu
set -o pipefail

DATA=/home/user/.arbitrum
CHAIN_INFO=/config/chainInfo.json
MARKER="$DATA/.dvn-snapshot"          # written once a restore completes
INCOMPLETE="$DATA/.dvn-snapshot-incomplete"
NITRO_UID="${FOLLOWER_UID:-1000}"

log() { echo "[restore] $*"; }
die() { echo "[restore] ERROR: $*" >&2; exit 1; }

# This container is the first to mount the volume, so Docker creates it owned by
# root, and Nitro (uid 1000) couldn't write to it. The top directory only: cheap
# even on a full volume.
chown "$NITRO_UID:$NITRO_UID" "$DATA"

URL="${FOLLOWER_SNAPSHOT_URL:-}"
if [ -z "$URL" ]; then
    log "No FOLLOWER_SNAPSHOT_URL: the follower syncs the chain from genesis."
    exit 0
fi
case "$URL" in
    https://*) ;;
    http://*) log "WARNING: FOLLOWER_SNAPSHOT_URL is plain http; use https unless it's a mirror on your own network." ;;
    *) die "FOLLOWER_SNAPSHOT_URL must be an http(s) URL (got '${URL%%\?*}'); for a gs:// object, use a signed https URL." ;;
esac
SCHEME="${FOLLOWER_SNAPSHOT_STATE_SCHEME:-path}"
case "$SCHEME" in
    hash|path) ;;
    *) die "FOLLOWER_SNAPSHOT_STATE_SCHEME must be hash or path (got '$SCHEME')." ;;
esac

[ -s "$CHAIN_INFO" ] || die "$CHAIN_INFO is missing (did nitro-follower-init succeed?)."
command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null
# Nitro reads <data>/<chain name>/nitro.
CHAIN=$(jq -r '.[0]["chain-name"] // empty' "$CHAIN_INFO")
[ -n "$CHAIN" ] || die "chainInfo.json has no chain-name."
DIR="$DATA/$CHAIN/nitro"

if [ -f "$INCOMPLETE" ]; then
    log "An earlier restore didn't finish; removing what it wrote and starting over."
    rm -rf "$DIR"
    rm -f "$INCOMPLETE"
fi
if [ -n "$(ls -A "$DIR/l2chaindata" 2>/dev/null)" ]; then
    if [ -f "$MARKER" ]; then
        log "The follower's database was restored from a snapshot ($(sed -n 's/^restored-at=//p' "$MARKER")); nothing to do."
    else
        log "The follower already has a database; not restoring a snapshot over it."
    fi
    exit 0
fi

# GNU tar (BusyBox's handles fewer archive formats) and curl.
apk add --no-cache curl tar >/dev/null

# Probe with a 1-byte range: an expired or wrong URL fails here with a clear
# message instead of after a partial download, and the response gives the size.
# (A HEAD request doesn't work: a signed URL is signed for GET.)
HDR=$(mktemp)
curl -sS -L -r 0-0 -D "$HDR" "$URL" 2>/dev/null | head -c 1 >/dev/null || true
STATUS=$(grep -E '^HTTP/' "$HDR" | tail -1 | awk '{print $2}' || true)
case "$STATUS" in
    200|206) ;;
    400|401|403)
        die "The snapshot server refused the URL (HTTP $STATUS). A signed URL expires (after at most 7 days): ask the DVN for a new one, or empty FOLLOWER_SNAPSHOT_URL to sync from genesis." ;;
    404) die "No snapshot at that URL (HTTP 404)." ;;
    "") die "Couldn't reach the snapshot server (no HTTP response). Check the URL and this host's internet access." ;;
    *) die "The snapshot server answered HTTP $STATUS." ;;
esac
SIZE=$(tr -d '\r' < "$HDR" | sed -n 's|^[Cc]ontent-[Rr]ange: bytes [0-9]*-[0-9]*/\([0-9]*\)$|\1|p' | tail -1 || true)
[ -n "$SIZE" ] || SIZE=$(tr -d '\r' < "$HDR" | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9]*\)$/\1/p' | tail -1 || true)
rm -f "$HDR"
gib() { awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f GiB", b / 1073741824; else printf "%.0f MiB", b / 1048576 }'; }

if [ -n "$SIZE" ] && [ "$SIZE" -gt 1 ]; then
    FREE=$(( $(df -Pk "$DATA" | awk 'NR==2 {print $4}') * 1024 ))
    # Room for the snapshot plus 10%: the follower starts writing as soon as it runs.
    NEED=$(( SIZE + SIZE / 10 ))
    [ "$FREE" -ge "$NEED" ] \
        || die "The snapshot is $(gib "$SIZE"); the follower volume has $(gib "$FREE") free and needs at least $(gib "$NEED"). Give Docker's data disk more space, then run docker compose up -d again."
    log "Restoring a $(gib "$SIZE") snapshot into $DIR ($(gib "$FREE") free); progress every minute."
else
    SIZE=""
    log "Restoring a snapshot (size unknown) into $DIR."
fi

ATTEMPTS="${FOLLOWER_SNAPSHOT_ATTEMPTS:-3}"
attempt=1
while :; do
    : > "$INCOMPLETE"
    rm -rf "$DIR"
    mkdir -p "$DIR"
    start=$(date +%s)
    ( while sleep 60; do
          done_b=$(( $(du -sk "$DIR" | cut -f1) * 1024 ))
          el=$(( $(date +%s) - start ))
          rate=$(( done_b / (el > 0 ? el : 1) ))
          if [ -n "$SIZE" ] && [ "$rate" -gt 0 ]; then
              log "$(gib "$done_b") of $(gib "$SIZE") ($(( done_b * 100 / SIZE ))%), $(awk -v r="$rate" 'BEGIN { printf "%.1f", r / 1048576 }') MiB/s, about $(( (SIZE - done_b) / rate / 60 )) min left"
          else
              log "$(gib "$done_b") so far"
          fi
      done ) &
    progress=$!
    # A stall (under 100 KiB/s for 5 minutes) fails the attempt rather than hanging.
    # No curl --retry: a retried download would append to the tar stream.
    # --ignore-zeros: read to the end of the stream. The snapshot is padded with
    # zeros past its end-of-archive marker (a 1 MiB record size), and tar stopping
    # there would cut curl off mid-download; it also extracts a snapshot published
    # as concatenated parts. A truncated download still fails: curl exits non-zero.
    if curl -fsSL --speed-limit 102400 --speed-time 300 "$URL" \
        | tar -x --ignore-zeros --no-same-owner --no-same-permissions -C "$DIR" -f -; then
        kill "$progress" 2>/dev/null || true
        break
    fi
    kill "$progress" 2>/dev/null || true
    [ "$attempt" -lt "$ATTEMPTS" ] || die "The snapshot didn't download after $ATTEMPTS attempts; see the errors above. Run docker compose up -d to try again."
    attempt=$((attempt + 1))
    log "The download failed; trying again from the start (attempt $attempt of $ATTEMPTS) in 30s."
    sleep 30
done

[ -f "$DIR/l2chaindata/CURRENT" ] \
    || die "The archive doesn't hold a Nitro database at its root (no l2chaindata/CURRENT): is FOLLOWER_SNAPSHOT_URL the right file?"
chown -R "$NITRO_UID:$NITRO_UID" "$DATA/$CHAIN"
cat > "$MARKER" <<EOF
url=${URL%%\?*}
state-scheme=$SCHEME
restored-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bytes=${SIZE:-unknown}
EOF
chown "$NITRO_UID:$NITRO_UID" "$MARKER"
rm -f "$INCOMPLETE"
log "Restored in $(( ($(date +%s) - start) / 60 )) min. The follower starts with the $SCHEME state scheme and catches up from the snapshot's block."
