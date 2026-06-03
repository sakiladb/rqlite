# sakiladb/rqlite — Design

**Status:** approved (brainstorm)
**Date:** 2026-06-02
**Author:** neilotoole

## Goal

Publish a `sakiladb/rqlite` Docker image preloaded with the Sakila example database, matching the conventions of the sibling images in this org (`sakiladb/postgres`, `sakiladb/mysql`, `sakiladb/clickhouse`, `sakiladb/sqlserver`). The image's primary consumer is the [sq](https://github.com/neilotoole/sq) `drivers/rqlite/` work (see neilotoole/sq#444), which needs a reproducible, network-reachable rqlite instance with Sakila preloaded for integration tests.

## Non-goals

- TLS / mTLS.
- Configurable credentials via environment variables (no sibling image does this).
- A 5-node cluster harness (3 nodes covers the Raft semantics sq cares about).
- A standalone `sakiladb/sqlite` image (if ever wanted, separate repo).
- Production hardening — this image exists for development and CI.

## Constraints

- Must boot to a usable state within a few seconds (no per-startup seeding).
- Must follow the layout and credential conventions in `../CLAUDE.planning.md` (database `sakila`, user `sakila`, password `p_ssW0rd`).
- Must build multi-arch (`linux/amd64`, `linux/arm64`) under the existing GitHub Actions / Docker Hub workflow used by sibling repos.
- The auth model must be on by default to match every other sakiladb image; sq's driver will use `http://sakila:p_ssW0rd@host:4001`.

## Background

rqlite is a distributed relational database that uses SQLite as its storage engine and Raft for replication. The official image is `rqlite/rqlite`, exposes ports 4001 (HTTP API) and 4002 (Raft), and stores state under `/rqlite/file/data`.

rqlite supports two ways to initialize from an existing SQLite file:

- **`POST /boot`** — single-node only; the fastest path. Recommended for build-time seeding.
- **`POST /db/load`** — works with clusters; slower; intended for runtime restore from backup.

A 5.6 MB Sakila SQLite file already exists in this repo at `../archive/sqlite-sakila-db/sakila.db` (SQLite 3.28, 2020) — same DVD-rental dataset shipped by every other sakiladb image. We use it verbatim as the seed.

Auth in rqlite is provided by a JSON file passed via `-auth /path/to/auth.json`. There is no environment-variable shortcut.

## Architecture

```
                  ┌──────────────────────────────────┐
                  │  Builder stage (multi-stage)     │
                  │  FROM rqlite/rqlite:${VERSION}   │
                  │                                  │
                  │  1. rqlited -node-id 1 &         │
                  │  2. wait /readyz                 │
                  │  3. POST /boot ← sakila.db       │
                  │  4. verify SELECT count(*)       │
                  │  5. SIGTERM + sync               │
                  │                                  │
                  │  → /rqlite/file/data (baked)     │
                  └────────────────┬─────────────────┘
                                   │ COPY --from=builder
                                   ▼
                  ┌──────────────────────────────────┐
                  │  Final image                     │
                  │  FROM rqlite/rqlite:${VERSION}   │
                  │  /rqlite/file/data    (baked)    │
                  │  /rqlite/auth.json    (bundled)  │
                  │  CMD: -auth -node-id 1 ...       │
                  └──────────────────────────────────┘
                                   │
                  ┌────────────────┴─────────────────┐
                  ▼                                  ▼
        single-node run                  cluster-compose.yml
        docker run -p 4001:4001          rqlite1 (uses baked data → leader)
                                         rqlite2 (empty vol, -join rqlite1)
                                         rqlite3 (empty vol, -join rqlite1)
```

The same image binary serves both modes. Compose nodes 2 and 3 mount empty named volumes over `/rqlite/file/data`, which masks the baked data; they come up empty and receive Sakila via Raft snapshot when they join node 1.

## Repo layout

```
rqlite/
├── .github/workflows/docker-publish.yml   # from postgres/, retargeted
├── .gitignore
├── Dockerfile
├── LICENSE                                 # present
├── README.md                               # replace stub
├── auth.json                               # basic-auth config
├── cluster-compose.yml                     # 3-node harness
├── docker-run.sh                           # single-node helper
├── sakila.db                               # copied from ../archive/sqlite-sakila-db/sakila.db
└── docs/superpowers/specs/                 # this document
```

## Components

### 1. Dockerfile (multi-stage)

```dockerfile
ARG RQLITE_VERSION=latest
FROM rqlite/rqlite:${RQLITE_VERSION} AS builder

USER root
RUN apk add --no-cache curl

COPY sakila.db /seed/sakila.db
COPY auth.json /rqlite/auth.json

ENV NODE_ID=1 DATA_DIR=/rqlite/file/data

RUN mkdir -p "$DATA_DIR" && \
    rqlited -node-id 1 \
        -http-addr 0.0.0.0:4001 -raft-addr 0.0.0.0:4002 \
        -http-adv-addr rqlite1:4001 -raft-adv-addr rqlite1:4002 \
        "$DATA_DIR" & \
    PID=$! && \
    for i in $(seq 1 60); do \
        curl -sf http://localhost:4001/readyz >/dev/null && break; \
        sleep 1; \
    done && \
    curl -sf -XPOST -H 'Transfer-Encoding: chunked' \
        --upload-file /seed/sakila.db http://localhost:4001/boot && \
    sleep 2 && \
    curl -sf 'http://localhost:4001/db/query?level=strong' \
        --data-urlencode 'q=SELECT count(*) FROM actor' | grep -q '"values":\[\[200\]\]' && \
    kill -TERM $PID && wait $PID 2>/dev/null || true && \
    sync

FROM rqlite/rqlite:${RQLITE_VERSION}
COPY --from=builder /rqlite/file/data /rqlite/file/data
COPY --from=builder /rqlite/auth.json /rqlite/auth.json
EXPOSE 4001 4002
CMD ["-auth=/rqlite/auth.json", "-node-id=1", \
     "-http-adv-addr=rqlite1:4001", "-raft-adv-addr=rqlite1:4002"]
```

Notes on choices:

- **Advertise addresses baked as `rqlite1`.** This name is what compose uses for the leader's service name. For single-node `docker run`, `docker-run.sh` adds `--add-host rqlite1:127.0.0.1` so the bake-time hostname still resolves. This keeps the baked Raft state portable between single-node and cluster modes.
- **`sleep 2 && sync`** before SIGTERM gives Raft a moment to fsync the boot snapshot. Belt-and-braces.
- **`grep -q '"values":\[\[200\]\]'`** turns the verify into a build-failing assertion (Sakila must have exactly 200 actors).
- **`RQLITE_VERSION` build arg** lets us publish version-pinned tags (e.g. `sakiladb/rqlite:8`) by overriding the arg in GitHub Actions, matching how `sakiladb/postgres` publishes `:15`.

### 2. auth.json

```json
[
  {"username": "sakila", "password": "p_ssW0rd", "perms": ["all"]},
  {"username": "*",                              "perms": ["status", "ready"]}
]
```

The wildcard entry lets `/status` and `/readyz` answer without credentials, which is useful for container healthchecks and CI smoke tests that don't want to embed creds.

### 3. cluster-compose.yml

```yaml
services:
  rqlite1:
    image: sakiladb/rqlite:latest
    container_name: rqlite1
    ports: ["4001:4001", "4002:4002"]
    # Uses baked /rqlite/file/data → starts as a single-voter cluster
    # that has Sakila and is ready to accept joiners.

  rqlite2:
    image: sakiladb/rqlite:latest
    container_name: rqlite2
    ports: ["4003:4001"]
    volumes:
      - rqlite2_data:/rqlite/file/data   # masks baked data
    command:
      - "-auth=/rqlite/auth.json"
      - "-node-id=2"
      - "-http-addr=0.0.0.0:4001"
      - "-raft-addr=0.0.0.0:4002"
      - "-http-adv-addr=rqlite2:4001"
      - "-raft-adv-addr=rqlite2:4002"
      - "-join=http://rqlite1:4001"
      - "-join-as=sakila"
    depends_on: [rqlite1]

  rqlite3:
    image: sakiladb/rqlite:latest
    container_name: rqlite3
    ports: ["4005:4001"]
    volumes:
      - rqlite3_data:/rqlite/file/data
    command:
      - "-auth=/rqlite/auth.json"
      - "-node-id=3"
      - "-http-addr=0.0.0.0:4001"
      - "-raft-addr=0.0.0.0:4002"
      - "-http-adv-addr=rqlite3:4001"
      - "-raft-adv-addr=rqlite3:4002"
      - "-join=http://rqlite1:4001"
      - "-join-as=sakila"
    depends_on: [rqlite1]

volumes:
  rqlite2_data:
  rqlite3_data:
```

After `docker compose up -d`, sq can target:
- single-node behavior → `http://sakila:p_ssW0rd@localhost:4001`
- cluster behavior → any of `localhost:4001|4003|4005`; gorqlite handles leader discovery.

### 4. docker-run.sh

```bash
#!/usr/bin/env bash
docker run -p 4001:4001 -p 4002:4002 \
    --add-host rqlite1:127.0.0.1 \
    -d sakiladb/rqlite:latest
```

`--add-host` makes the baked advertise hostname resolve in single-node mode.

### 5. README.md

Replaces the current one-line stub. Same shape as `postgres/README.md`:

- intro + credentials (`sakila` / `p_ssW0rd`, port 4001)
- single-node quickstart (`docker run` + curl smoke test)
- cluster quickstart (`docker compose up -d` + ports table)
- link to Docker Hub tags
- link to upstream `rqlite/rqlite`

### 6. .github/workflows/docker-publish.yml

Copy `postgres/.github/workflows/docker-publish.yml`. Change:
- branch / tag triggers to `master`, `rqlite-*`
- image name flows automatically via `${{ github.repository }}` → `sakiladb/rqlite`
- keep multi-arch (`linux/amd64,linux/arm64`), cosign signing, Docker Hub + GHCR push

### 7. .gitignore

Match siblings (IDE files, .DS_Store, build artifacts).

## Data flow

**Build time:**
1. `docker build` enters the builder stage on `rqlite/rqlite:${VERSION}`.
2. `sakila.db` and `auth.json` are copied in.
3. `rqlited` starts as node 1 in the background.
4. The build loop polls `/readyz` until the node is up (≤60 s).
5. `curl POST /boot` uploads `sakila.db` — rqlite ingests it as a Raft snapshot.
6. A `SELECT count(*) FROM actor` assertion fails the build if the count isn't 200.
7. `SIGTERM` shuts down rqlite; `sync` ensures fsync.
8. Final stage copies the baked `/rqlite/file/data` and `auth.json` into a fresh `rqlite/rqlite:${VERSION}` image.

**Single-node runtime:**
1. `docker run` invokes the default CMD with auth and advertise flags.
2. rqlite reopens the baked data dir, replays Raft, becomes leader of its single-voter cluster.
3. Sakila is immediately queryable on `:4001`.

**Cluster runtime (compose):**
1. `rqlite1` starts as above and becomes leader.
2. `rqlite2` / `rqlite3` start with empty volumes and `-join http://rqlite1:4001`.
3. They authenticate to node 1 as `sakila`, register as voters, and receive the Sakila state via Raft snapshot.
4. Within a few seconds, all three nodes serve the same Sakila data.

## Error handling

Failure modes worth thinking about:

| Failure                                       | Detection                              | Response                                                                 |
|-----------------------------------------------|----------------------------------------|--------------------------------------------------------------------------|
| rqlited never becomes ready during build      | 60 s `/readyz` loop                    | Build fails (loop exits with no success, `curl POST /boot` fails)        |
| `/boot` accepts but data is wrong             | `SELECT count(*) FROM actor` assertion | Build fails on grep                                                      |
| SIGTERM races Raft fsync                      | n/a (silent corruption risk)           | Mitigated by `sleep 2 && sync` before SIGTERM                            |
| Compose nodes 2/3 cannot resolve `rqlite1`    | rqlite logs                            | User-visible at `docker compose logs`; depends_on ensures ordering       |
| Single-node user forgets `--add-host rqlite1` | rqlited startup warning                | `docker-run.sh` adds it; documented in README. Listener still binds 0.0.0.0 so HTTP queries from the host still work; only inter-node Raft would care, and single-node has none. |

Items to validate during implementation (the "unknown unknowns" worth calling out):

1. **Does a post-`/boot` data dir actually accept later joiners?** The rqlite docs describe `/boot` as "exclusively for single-node setups" but don't explicitly say a post-boot cluster can be expanded. Plausible — boot leaves a normal single-voter Raft state — but needs a hands-on check before the cluster-compose harness is shipped.
2. **Are advertise addresses persisted in Raft state, or re-read from flags on each start?** If persisted, the baked `rqlite1:4002` may need a one-time override on first startup. We'll discover this in the first build.
3. **Is `-join-as=<username>` the right flag for joining an authed cluster?** Confirm against current rqlite docs during implementation.
4. **Is `"username": "*"` the right wildcard syntax in `auth.json` for granting unauthenticated access to `status` / `ready`?** Surfaced from the rqlite docs but not verified end-to-end. Fallback if it doesn't work: drop the wildcard entry and add `-u sakila:p_ssW0rd` to the healthcheck.

## Verification

Build-time assertion (in the Dockerfile RUN): `SELECT count(*) FROM actor` returns 200.

Post-build smoke tests (documented in README):

```bash
# Single-node
docker run -p 4001:4001 --add-host rqlite1:127.0.0.1 -d sakiladb/rqlite:latest
curl -u sakila:p_ssW0rd 'http://localhost:4001/db/query?level=strong' \
    --data-urlencode 'q=SELECT count(*) FROM actor'
# → {"results":[{"columns":["count(*)"],"types":[""],"values":[[200]]}]}

# Cluster
docker compose -f cluster-compose.yml up -d
for port in 4001 4003 4005; do
  curl -s -u sakila:p_ssW0rd "http://localhost:$port/status" | jq '.store.raft.state'
done
# → one "Leader", two "Follower"
```

Expected row counts (canonical Sakila, per `../CLAUDE.planning.md`):

| table     | expected |
|-----------|----------|
| actor     | 200      |
| film      | 1000     |
| customer  | 599      |
| inventory | 4581     |
| rental    | 16044    |
| payment   | 16049    |

## Open questions for implementation

1. Whether `RQLITE_VERSION` should default to `latest` or to a pinned version (e.g. `8`). Sibling repos pin (`postgres:15-alpine`); rqlite tags are simpler. Default `latest` for v1, revisit when we add version-suffixed image tags.
2. Whether to add a `healthcheck:` block to the Dockerfile (e.g. `curl -f http://localhost:4001/readyz`). Sibling images don't, but it's cheap and useful for compose. Likely yes — defer to plan.

## Out of scope

See "Non-goals" above. Specifically not in this design: TLS, configurable creds, 5-node cluster, custom seed datasets, runtime data-reload commands.

## References

- `../CLAUDE.planning.md` — the sibling-image implementation checklist
- `../postgres/Dockerfile` — multi-stage bake reference
- `../clickhouse/Dockerfile` — multi-stage bake with verification step reference
- rqlite docs: <https://rqlite.io/docs/install-rqlite/>, <https://rqlite.io/docs/guides/backup/>, <https://rqlite.io/docs/guides/security/>
- neilotoole/sq#444 — the consumer driver issue
