#!/bin/sh
# One-shot init: on an empty follower volume, restore the chain database from a
# snapshot, so the follower catches up from the snapshot's block instead of
# re-executing the chain from genesis (days to weeks on a long-running chain).
#
# The snapshot is a tar of a Nitro node's data directory (l2chaindata/,
# arbitrumdata/, ... at its root), from one of:
#   - a file in the bundle's snapshot/ folder (mounted at /snapshot): latest.tar,
#     or the parts snapshot_part_*.tar.part of a split one. E.g. the DVN's
#     full-node snapshot, downloaded with
#       gcloud storage cp gs://conduit-networks-snapshots/<chain>/full/latest.tar ./snapshot/ --billing-project=<project>
#     gcloud writes <file>_.gstmp and renames it once its checksum matches, so a
#     .gstmp file means a download is unfinished: the restore refuses to go on
#     (the follower would otherwise start from genesis, and the snapshot would be
#     ignored from then on). Restoring from a file takes the snapshot's size in
#     free disk again, until the file is deleted.
#   - FOLLOWER_SNAPSHOT_URL, an http(s) URL (a public or signed link). It's
#     streamed straight into the volume (curl | tar -x), so it needs only the
#     snapshot's size in free disk.
# A file wins over the URL.
#
# Runs on every `docker compose up` (compose restarts one-shot services), and does
# nothing when the volume already holds a database: a file or URL is only used for
# an empty volume, so a snapshot file left in snapshot/, or a signed URL left in
# .env after it expires, does no harm. A restore that was interrupted (the
# container stopped, the download failed) is wiped and started over on the next
# run.
#
# Env:
#   FOLLOWER_SNAPSHOT_URL           the snapshot's URL (empty, and no file in
#                                   snapshot/: sync from genesis)
#   FOLLOWER_SNAPSHOT_STATE_SCHEME  the snapshot's state scheme (default path, the
#                                   DVN's snapshots); the follower starts with it
#   FOLLOWER_SNAPSHOT_ATTEMPTS      downloads to try before giving up (default 3)
#   FOLLOWER_UID                    the Nitro image's user (default 1000)
set -eu
set -o pipefail

DATA=/home/user/.arbitrum
SNAPSHOT_DIR=/snapshot
CHAIN_INFO=/config/chainInfo.json
MARKER="$DATA/.dvn-snapshot"          # written once a restore completes
INCOMPLETE="$DATA/.dvn-snapshot-incomplete"
NITRO_UID="${FOLLOWER_UID:-1000}"

log() { echo "[restore] $*"; }
die() { echo "[restore] ERROR: $*" >&2; exit 1; }
gib() { awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f GiB", b / 1073741824; else printf "%.0f MiB", b / 1048576 }'; }

# This container is the first to mount the volume, so Docker creates it owned by
# root, and Nitro (uid 1000) couldn't write to it. The top directory only: cheap
# even on a full volume.
chown "$NITRO_UID:$NITRO_UID" "$DATA"

# The snapshot's source: a file in snapshot/ (whole, or a split one's parts in
# name order), else the URL.
FILES=""
if [ -f "$SNAPSHOT_DIR/latest.tar" ]; then
    FILES="$SNAPSHOT_DIR/latest.tar"
elif ls "$SNAPSHOT_DIR"/snapshot_part_*.tar.part >/dev/null 2>&1; then
    FILES=$(ls "$SNAPSHOT_DIR"/snapshot_part_*.tar.part | LC_ALL=C sort)
fi
PENDING=$(ls "$SNAPSHOT_DIR"/*_.gstmp 2>/dev/null || true)
URL="${FOLLOWER_SNAPSHOT_URL:-}"

if [ -z "$FILES" ] && [ -z "$PENDING" ] && [ -z "$URL" ]; then
    if ls "$DATA"/*/nitro/l2chaindata/CURRENT >/dev/null 2>&1; then
        log "The follower has a database; nothing to restore."
    else
        log "No snapshot (none in snapshot/, no FOLLOWER_SNAPSHOT_URL): the follower syncs the chain from genesis."
    fi
    exit 0
fi
if [ -z "$FILES" ] && [ -n "$URL" ]; then
    case "$URL" in
        https://*) ;;
        http://*) log "WARNING: FOLLOWER_SNAPSHOT_URL is plain http; use https unless it's a mirror on your own network." ;;
        gs://*) die "FOLLOWER_SNAPSHOT_URL is a gs:// path, which needs your Google credentials: download it into the bundle's snapshot/ folder with gcloud instead (see the README), and empty FOLLOWER_SNAPSHOT_URL." ;;
        *) die "FOLLOWER_SNAPSHOT_URL must be an http(s) URL (got '${URL%%\?*}')." ;;
    esac
fi
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
        [ -z "$FILES" ] || log "You can delete the snapshot file(s) in snapshot/: they aren't needed again."
    else
        log "The follower already has a database; not restoring a snapshot over it."
        log "To start over from the snapshot: docker compose down, docker volume rm <folder>_follower-data, docker compose up -d."
    fi
    exit 0
fi

if [ -n "$PENDING" ]; then
    die "A download into snapshot/ isn't finished ($(basename "$(echo "$PENDING" | head -1)")): run docker compose up -d once gcloud has finished. If no download is running, delete the .gstmp file and download again."
fi

# The volume needs room for the snapshot plus 10%: the follower starts writing as
# soon as it runs.
check_free() {
    FREE=$(( $(df -Pk "$DATA" | awk 'NR==2 {print $4}') * 1024 ))
    NEED=$(( SIZE + SIZE / 10 ))
    [ "$FREE" -ge "$NEED" ] \
        || die "The snapshot is $(gib "$SIZE"); the follower volume has $(gib "$FREE") free and needs at least $(gib "$NEED"). Give Docker's data disk more space, then run docker compose up -d again."
}

# Progress every minute, from what has landed in the volume.
start_progress() {
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
}
stop_progress() { kill "$progress" 2>/dev/null || true; }

# Start each attempt from an empty directory, marked incomplete until finish.
prepare_dir() {
    : > "$INCOMPLETE"
    rm -rf "$DIR"
    mkdir -p "$DIR"
}

# Check the database, hand it to Nitro's user, and write the marker the follower
# reads its state scheme from.
finish() {
    [ -f "$DIR/l2chaindata/CURRENT" ] \
        || die "The archive doesn't hold a Nitro database at its root (no l2chaindata/CURRENT): is it the right file?"
    chown -R "$NITRO_UID:$NITRO_UID" "$DATA/$CHAIN"
    cat > "$MARKER" <<EOF
source=$1
state-scheme=$SCHEME
restored-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bytes=${SIZE:-unknown}
EOF
    chown "$NITRO_UID:$NITRO_UID" "$MARKER"
    rm -f "$INCOMPLETE"
    log "Restored in $(( ($(date +%s) - start) / 60 )) min. The follower starts with the $SCHEME state scheme and catches up from the snapshot's block."
}

# GNU tar (BusyBox's handles fewer archive formats).
apk add --no-cache tar >/dev/null

# --ignore-zeros (both sources): read past the zeros padding the archive after its
# end-of-archive marker (a 1 MiB record size) and across the parts of a split
# snapshot. Stopping at the marker would also cut curl off mid-download.

if [ -n "$FILES" ]; then
    [ -z "$URL" ] || log "Using the snapshot in snapshot/; FOLLOWER_SNAPSHOT_URL isn't used."
    SIZE=0
    for f in $FILES; do SIZE=$(( SIZE + $(stat -c %s "$f") )); done
    NAMES=$(for f in $FILES; do basename "$f"; done | tr '\n' ' ' | sed 's/ $//')
    check_free
    log "Restoring the $(gib "$SIZE") snapshot in snapshot/ ($NAMES) into $DIR ($(gib "$FREE") free); progress every minute."
    prepare_dir
    start_progress
    # gcloud checked the file against the bucket's checksum, so a failure here
    # means it was cut or changed since: no retry.
    # shellcheck disable=SC2086
    if ! cat $FILES | tar -x --ignore-zeros --no-same-owner --no-same-permissions -C "$DIR" -f -; then
        stop_progress
        die "Couldn't extract the snapshot in snapshot/: the file may be incomplete or damaged. Delete it, download it again, then run docker compose up -d."
    fi
    stop_progress
    finish "file:$NAMES"
    log "You can delete the snapshot file(s) in snapshot/ now: they aren't needed again."
    exit 0
fi

apk add --no-cache curl >/dev/null

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

if [ -n "$SIZE" ] && [ "$SIZE" -gt 1 ]; then
    check_free
    log "Restoring a $(gib "$SIZE") snapshot into $DIR ($(gib "$FREE") free); progress every minute."
else
    SIZE=""
    log "Restoring a snapshot (size unknown) into $DIR."
fi

ATTEMPTS="${FOLLOWER_SNAPSHOT_ATTEMPTS:-3}"
attempt=1
while :; do
    prepare_dir
    start_progress
    # A stall (under 100 KiB/s for 5 minutes) fails the attempt rather than hanging.
    # No curl --retry: a retried download would append to the tar stream. A
    # truncated download fails: curl exits non-zero.
    if curl -fsSL --speed-limit 102400 --speed-time 300 "$URL" \
        | tar -x --ignore-zeros --no-same-owner --no-same-permissions -C "$DIR" -f -; then
        stop_progress
        break
    fi
    stop_progress
    [ "$attempt" -lt "$ATTEMPTS" ] || die "The snapshot didn't download after $ATTEMPTS attempts; see the errors above. Run docker compose up -d to try again."
    attempt=$((attempt + 1))
    log "The download failed; trying again from the start (attempt $attempt of $ATTEMPTS) in 30s."
    sleep 30
done

finish "${URL%%\?*}"
