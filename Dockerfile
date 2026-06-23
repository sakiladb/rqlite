# syntax=docker/dockerfile:1.6

ARG RQLITE_VERSION=10.2.0

# ---- Builder stage: boot rqlite, seed via /boot, cleanly shut down ----
#
# Pinned to $BUILDPLATFORM so the bake ALWAYS runs on the native build host,
# never under QEMU. rqlited is a full Go server (raft, BoltDB mmap, HTTP); under
# QEMU user-mode emulation it reports ready but then fails to serve queries
# after /boot, so an emulated arm64 bake times out (gh#8 was this failure,
# silently shipped empty by the old `|| true`). The baked data dir is
# architecture-independent — db.sqlite and the raft snapshots are SQLite, and
# raft.db is a little-endian/4K-page BoltDB file readable by both amd64 and
# arm64 — so we bake once here and COPY it into every target image below.
FROM --platform=$BUILDPLATFORM rqlite/rqlite:${RQLITE_VERSION} AS builder

# Cache-bust marker. Bumping this string forces every downstream layer
# to rebuild even when BuildKit's per-instruction hashing matches an
# older cache entry (which happened to v10.0.1 — see commit history).
LABEL build.cachebust="v10.0.5-2026-06-23"

USER root
RUN apk add --no-cache curl

COPY sakila.db /staging/sakila.db
COPY auth.json /staging/auth.json
COPY tools/bake.sh /staging/bake.sh

# Bake into /staging/sakila-data, NOT /rqlite/file/data. The base
# image declares VOLUME /rqlite/file, which means:
#   (a) RUN writes under that path are discarded from the layer
#       (BuildKit/buildx semantics, especially multi-arch); and
#   (b) COPY into a SUBDIR of a VOLUME path is also discarded by
#       BuildKit (verified empirically — produced a 0-byte layer).
# The sibling postgres image works because it COPYs to *exactly*
# the VOLUME path. For us, the cleanest fix is to bypass the
# inherited VOLUME entirely: the final stage COPYs into a brand
# new non-VOLUME path (/var/lib/sakiladb/data) and sets
# DATA_DIR so rqlited reads from there. The /rqlite/file VOLUME
# inherited from the base image is left unused (harmless).
#
# bake.sh seeds the data, then restarts a fresh node from the
# persisted dir and re-verifies — so an empty/incomplete bake
# (gh#8) fails the build instead of being published. `set -eu`
# inside makes every step fatal.
RUN sh /staging/bake.sh

# ---- Final stage: ship the baked data dir + auth config ----
FROM rqlite/rqlite:${RQLITE_VERSION}

# /var/lib/sakiladb is outside the inherited VOLUME /rqlite/file, so
# the COPY layer persists. DATA_DIR points rqlited (via the base
# image's docker-entrypoint.sh) at the baked location.
COPY --chown=rqlite:rqlite --from=builder /staging/sakila-data /var/lib/sakiladb/data
COPY --chown=rqlite:rqlite --from=builder /staging/auth.json /rqlite/auth.json

ENV DATA_DIR=/var/lib/sakiladb/data

EXPOSE 4001 4002

CMD ["-auth=/rqlite/auth.json", \
     "-node-id=1", \
     "-http-adv-addr=rqlite1:4001", \
     "-raft-adv-addr=rqlite1:4002"]
