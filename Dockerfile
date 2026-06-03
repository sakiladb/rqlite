# syntax=docker/dockerfile:1.6

ARG RQLITE_VERSION=10.2.0

# ---- Builder stage: boot rqlite, seed via /boot, cleanly shut down ----
FROM rqlite/rqlite:${RQLITE_VERSION} AS builder

# Cache-bust marker. Bumping this string forces every downstream layer
# to rebuild even when BuildKit's per-instruction hashing matches an
# older cache entry (which happened to v10.0.1 — see commit history).
LABEL build.cachebust="v10.0.3-2026-06-03"

USER root
RUN apk add --no-cache curl

COPY sakila.db /staging/sakila.db
COPY auth.json /staging/auth.json

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
RUN mkdir -p /staging/sakila-data && \
    rqlited -node-id 1 \
        -http-addr 0.0.0.0:4001 -raft-addr 0.0.0.0:4002 \
        -http-adv-addr rqlite1:4001 -raft-adv-addr rqlite1:4002 \
        /staging/sakila-data & \
    PID=$! && \
    echo "Waiting for rqlite to be ready..." && \
    for i in $(seq 1 60); do \
        if curl -sf http://localhost:4001/readyz >/dev/null 2>&1; then \
            echo "rqlite ready after ${i}s"; break; \
        fi; \
        sleep 1; \
    done && \
    if ! curl -sf http://localhost:4001/readyz >/dev/null; then \
        echo "ERROR: rqlite did not become ready within 60s"; exit 1; \
    fi && \
    echo "Booting Sakila from /staging/sakila.db..." && \
    curl -sf -XPOST -H 'Transfer-Encoding: chunked' \
        --upload-file /staging/sakila.db \
        http://localhost:4001/boot && \
    sleep 2 && \
    echo "Verifying row counts..." && \
    curl -sf \
        'http://localhost:4001/db/query?level=strong&q=SELECT+count(*)+FROM+actor' \
        | grep -q '"values":\[\[200\]\]' && \
    curl -sf \
        'http://localhost:4001/db/query?level=strong&q=SELECT+count(*)+FROM+film' \
        | grep -q '"values":\[\[1000\]\]' && \
    curl -sf \
        'http://localhost:4001/db/query?level=strong&q=SELECT+count(*)+FROM+rental' \
        | grep -q '"values":\[\[16044\]\]' && \
    echo "Sakila baked successfully" && \
    kill -TERM "$PID" && \
    wait "$PID" 2>/dev/null || true && \
    sync && \
    chown -R 1000:1000 /staging/sakila-data && \
    ls -la /staging/sakila-data

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
