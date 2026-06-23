#!/bin/sh
# bake.sh — seed Sakila into an rqlite data dir at image-build time, then
# PROVE the persisted artifact is real before the build is allowed to proceed.
#
# Why a script instead of an inline Dockerfile RUN: the previous inline
# version chained ~15 steps with `&&` and ended with `... wait "$PID" || true`.
# Because `&&`/`||` are equal-precedence and left-associative, that trailing
# `|| true` swallowed failures of the ENTIRE chain before it — including the
# row-count verification. A boot or verify failure under QEMU/CI therefore
# still exited 0, and an empty data dir got COPYed into the published image
# (gh#8). `set -eu` here makes every step fatal, full stop.
#
# Two phases:
#   1. Seed   — boot sakila.db into a fresh node, verify the RUNNING node.
#   2. Gate   — restart a brand-new rqlited from the SAME on-disk dir (exactly
#               what the shipped image does) and verify it serves from the
#               PERSISTED state. This is the check the old build never had:
#               it validates the artifact that actually gets shipped, so an
#               empty/incomplete bake fails the build instead of publishing.

set -eu

DATA_DIR=/staging/sakila-data
SRC=/staging/sakila.db

# Node identity must match the final image's runtime CMD so the baked raft
# state is consistent with how the container starts (-node-id=1, rqlite1).
start_node() {
    rqlited -node-id 1 \
        -http-addr 0.0.0.0:4001 -raft-addr 0.0.0.0:4002 \
        -http-adv-addr rqlite1:4001 -raft-adv-addr rqlite1:4002 \
        "$DATA_DIR" >/tmp/rqlited.log 2>&1 &
    NODE_PID=$!
}

wait_ready() {
    for i in $(seq 1 60); do
        if curl -sf http://localhost:4001/readyz >/dev/null 2>&1; then
            echo "  rqlite ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: rqlite did not become ready within 60s" >&2
    cat /tmp/rqlited.log >&2 || true
    return 1
}

# Strong-consistency read so the count reflects committed raft state, not a
# stale local copy.
assert_count() {
    table=$1
    want=$2
    got=$(curl -sf "http://localhost:4001/db/query?level=strong&q=SELECT+count(*)+FROM+$table" || true)
    if ! echo "$got" | grep -q "\"values\":\[\[$want\]\]"; then
        echo "ERROR: expected $want rows in $table, got: $got" >&2
        return 1
    fi
    echo "  $table = $want OK"
}

verify_all() {
    assert_count actor 200
    assert_count film 1000
    assert_count rental 16044
}

stop_node() {
    kill -TERM "$NODE_PID"
    # A TERM'd process exits non-zero; tolerate ONLY the wait, nothing else.
    wait "$NODE_PID" 2>/dev/null || true
    sync
}

mkdir -p "$DATA_DIR"

# ---- Phase 1: seed ----
echo "Phase 1: seeding Sakila from $SRC"
start_node
wait_ready
echo "  booting $SRC..."
curl -sf -XPOST -H 'Transfer-Encoding: chunked' \
    --upload-file "$SRC" \
    http://localhost:4001/boot
sleep 2
echo "  verifying running node..."
verify_all
stop_node

# ---- Phase 2: gate — verify the PERSISTED artifact, fresh process ----
# Restart a brand-new rqlited from the baked dir (exactly what the shipped
# image does) and re-assert the row counts. Serving the correct counts from a
# cold start IS the proof that the bake persisted: an empty or incomplete dir
# (gh#8) bootstraps a fresh node, verify_all then fails on the missing tables,
# and the build aborts. We deliberately gate on this observable behaviour
# rather than grepping rqlited's startup log for "preexisting node state" —
# that check was redundant with verify_all and brittle across rqlite versions.
echo "Phase 2: verifying persisted artifact (the dir that gets shipped)"
if [ ! -s "$DATA_DIR/db.sqlite" ]; then
    echo "ERROR: $DATA_DIR/db.sqlite is missing or empty after seed" >&2
    ls -la "$DATA_DIR" >&2 || true
    exit 1
fi
start_node
wait_ready
echo "  restarted from baked dir; verifying served data..."
verify_all
stop_node

chown -R 1000:1000 "$DATA_DIR"
echo "Sakila baked and verified (seeded + persisted-restart)."
ls -la "$DATA_DIR"
