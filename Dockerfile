# syntax=docker/dockerfile:1.6

ARG RQLITE_VERSION=latest

# ---- Builder stage: boot rqlite, seed via /boot, cleanly shut down ----
FROM rqlite/rqlite:${RQLITE_VERSION} AS builder

USER root
RUN apk add --no-cache curl bash

COPY sakila.db /seed/sakila.db
COPY auth.json /rqlite/auth.json

ENV NODE_ID=1
ENV DATA_DIR=/rqlite/file/data

RUN mkdir -p "$DATA_DIR" && \
    rqlited -node-id 1 \
        -http-addr 0.0.0.0:4001 -raft-addr 0.0.0.0:4002 \
        -http-adv-addr rqlite1:4001 -raft-adv-addr rqlite1:4002 \
        "$DATA_DIR" & \
    PID=$! && \
    echo "Waiting for rqlite to be ready..." && \
    for i in $(seq 1 60); do \
        if curl -sf http://localhost:4001/readyz >/dev/null 2>&1; then \
            echo "rqlite ready after ${i}s"; break; \
        fi; \
        sleep 1; \
    done && \
    curl -sf http://localhost:4001/readyz >/dev/null && \
    echo "Booting Sakila from /seed/sakila.db..." && \
    curl -sf -XPOST -H 'Transfer-Encoding: chunked' \
        --upload-file /seed/sakila.db \
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
    chown -R 1000:1000 "$DATA_DIR"

# ---- Final stage: ship the baked data dir + auth config ----
FROM rqlite/rqlite:${RQLITE_VERSION}

COPY --chown=rqlite:rqlite --from=builder /rqlite/file/data /rqlite/file/data
COPY --chown=rqlite:rqlite --from=builder /rqlite/auth.json /rqlite/auth.json

EXPOSE 4001 4002

CMD ["-auth=/rqlite/auth.json", \
     "-node-id=1", \
     "-http-adv-addr=rqlite1:4001", \
     "-raft-adv-addr=rqlite1:4002"]
