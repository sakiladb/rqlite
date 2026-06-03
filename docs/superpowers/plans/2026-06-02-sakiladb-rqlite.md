# sakiladb/rqlite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `sakiladb/rqlite` Docker image preloaded with the Sakila example database (basic-auth `sakila` / `p_ssW0rd`), plus a 3-node `docker compose` harness that reuses the same image. Built via a multi-stage Dockerfile that seeds rqlite from a SQLite file using rqlite's `/boot` endpoint at build time.

**Architecture:** A multi-stage Dockerfile. Stage 1 boots `rqlited` against an empty data dir, POSTs the Sakila SQLite file to `/boot`, verifies row counts, then cleanly shuts down. Stage 2 copies the resulting `/rqlite/file/data` (containing the Raft log + SQLite state) and the bundled `auth.json` into a fresh `rqlite/rqlite` base image. The image runs single-node by default; `cluster-compose.yml` launches 3 copies that form a Raft cluster (followers mount empty volumes that mask the baked data dir and join the leader).

**Tech Stack:** rqlite (`rqlite/rqlite` Docker image, currently major version 8), Docker (multi-stage build, BuildKit, multi-arch via `buildx`), Docker Compose, GitHub Actions (existing `postgres/` workflow as template), `curl` for `/boot` upload and verification.

**Spec:** `docs/superpowers/specs/2026-06-02-sakiladb-rqlite-design.md` (commit `da2dce8`).

**Sibling reference repos** (peer directories of this repo):
- `../postgres/Dockerfile` — multi-stage bake pattern
- `../clickhouse/Dockerfile` — multi-stage bake with verification step
- `../postgres/.github/workflows/docker-publish.yml` — CI template
- `../postgres/README.md` — README format
- `../CLAUDE.planning.md` — sibling implementation checklist (read once before starting)

**Existing repo state** (working dir `/Users/neilotoole/work/moi/sakiladb/rqlite`):
- `LICENSE` — keep, unchanged
- `README.md` — current one-line stub, will be replaced in Task 5
- `rqlite.iml` — IntelliJ project file, leave alone
- `docs/superpowers/specs/2026-06-02-sakiladb-rqlite-design.md` — the spec
- `docs/superpowers/plans/2026-06-02-sakiladb-rqlite.md` — this plan
- `.git/`

**Verification dataset (canonical Sakila row counts):**

| table     | expected count |
|-----------|---------------:|
| actor     | 200            |
| film      | 1000           |
| customer  | 599            |
| inventory | 4581           |
| rental    | 16044          |
| payment   | 16049          |

**Items the implementor needs to confirm during execution** (called out in the relevant task):
1. Does `POST /boot` actually leave the data dir in a state where additional Raft voters can later join? (resolved in Task 6)
2. Are `-http-adv-addr` / `-raft-adv-addr` persisted in Raft state, or re-read from flags on each start? (resolved in Task 3)
3. Is `-join-as=<username>` the correct flag for joining an authed cluster on current rqlite? (resolved in Task 6 — `rqlited --help | grep -i join` will tell us)
4. Is `"username": "*"` the right wildcard syntax in `auth.json` for granting unauthenticated access to `/status` / `/readyz`? (resolved in Task 3 — the build will fail at the `/readyz` poll if not)

If any assumption fails, stop and flag it rather than improvising — the spec discusses fallbacks.

## Empirical findings from Task 3 execution (must be honored by downstream tasks)

These were discovered when Task 3 actually built. Update everything else accordingly.

- **rqlite v10 `/db/query` does not accept `--data-urlencode` POSTs** (those return 400 "invalid JSON body"). Use the **GET** form instead:
  ```
  curl -sf -u sakila:p_ssW0rd 'http://localhost:PORT/db/query?level=strong&q=SELECT+count(*)+FROM+actor'
  ```
  All curl smoke tests in Tasks 5 / 6 / Final verification must use this GET form. `SELECT ... LIMIT 3` is `q=SELECT+first_name,last_name+FROM+actor+LIMIT+3`.
- **`/readyz` returns a four-line status body**, not a single `[+ok]`:
  ```
  [+]node ok
  [+]leader ok
  [+]store ok
  [+]db ok
  ```
  Tasks 5 / Final verification should reflect this in any "expected output" comparisons.
- **`/status` JSON shape (rqlite v10):**
  - HTTP advertise address → `s['cluster']['api_addr']` (e.g. `rqlite1:4001`)
  - Raft advertise address → `s['cluster']['addr']` (e.g. `rqlite1:4002`)
  - Raft role string → `s['store']['raft']['state']` (still as the design assumed — `Leader` / `Follower`)
  Use these paths in Task 6 / README rather than the speculative `s['store']['raft']['transport']['local_addr']` in earlier drafts.
- **Base image uid is 1000 (`rqlite`).** Task 3's Dockerfile handles this with `chown -R 1000:1000 "$DATA_DIR"` in the builder and `COPY --chown=rqlite:rqlite ...` in the final stage. No downstream task should need to revisit it, but be aware if you debug a "permission denied on /rqlite/file/data/extensions" failure.

---

## File Structure

Files this plan creates or modifies:

| Path                                       | Purpose                                                      | Task |
|--------------------------------------------|--------------------------------------------------------------|------|
| `sakila.db`                                | Seed SQLite file (copied verbatim from `../archive/`)        | 1    |
| `.gitignore`                               | Standard ignores (IDE, OS, build artifacts)                  | 1    |
| `auth.json`                                | rqlite basic-auth config                                     | 2    |
| `Dockerfile`                               | Multi-stage build (bake Sakila via `/boot`)                  | 3    |
| `docker-run.sh`                            | Single-node `docker run` helper                              | 4    |
| `README.md`                                | Replaces the stub; usage + smoke tests                       | 5    |
| `cluster-compose.yml`                      | 3-node Raft cluster harness                                  | 6    |
| `.github/workflows/docker-publish.yml`     | Multi-arch CI build + push to Docker Hub & GHCR              | 7    |

Each file has a single responsibility. The Dockerfile is the integration point; everything else either feeds into it (sakila.db, auth.json) or wraps it (run scripts, compose, README, CI).

---

## Task 1: Bring the Sakila seed file into the repo

**Files:**
- Create: `sakila.db` (binary copy from `../archive/sqlite-sakila-db/sakila.db`)
- Create: `.gitignore`

**Goal:** Have a verified Sakila SQLite file in the repo root so the Dockerfile can `COPY` it, and have a `.gitignore` so editor / OS junk doesn't get committed.

- [ ] **Step 1: Verify the source file exists and has the expected schema**

Run:
```bash
cd /Users/neilotoole/work/moi/sakiladb/rqlite
file ../archive/sqlite-sakila-db/sakila.db
sqlite3 ../archive/sqlite-sakila-db/sakila.db 'SELECT count(*) FROM actor;'
sqlite3 ../archive/sqlite-sakila-db/sakila.db 'SELECT count(*) FROM film;'
sqlite3 ../archive/sqlite-sakila-db/sakila.db 'SELECT count(*) FROM rental;'
sqlite3 ../archive/sqlite-sakila-db/sakila.db 'SELECT count(*) FROM payment;'
```

Expected output (counts must match exactly):
- `file` → `SQLite 3.x database, ...`
- `actor` → `200`
- `film` → `1000`
- `rental` → `16044`
- `payment` → `16049`

If any count is wrong, STOP and report — using a different Sakila SQLite source is a spec change.

- [ ] **Step 2: Copy the seed file into the repo root**

Run:
```bash
cp ../archive/sqlite-sakila-db/sakila.db ./sakila.db
ls -la sakila.db
```

Expected: file is roughly 5.6 MB and present at `./sakila.db`.

- [ ] **Step 3: Re-verify the copy is intact**

Run:
```bash
sqlite3 ./sakila.db 'SELECT count(*) FROM actor;'
```

Expected: `200`.

- [ ] **Step 4: Create `.gitignore`**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/.gitignore` with this exact content:

```gitignore
# OS / editor noise
.DS_Store
*.swp
*.swo
.idea/
.vscode/

# Build artifacts
*.tar
*.log
```

Note: `sakila.db` is intentionally NOT ignored — the Dockerfile depends on it being in the build context.

- [ ] **Step 5: Confirm git sees the right files**

Run:
```bash
git status --short
```

Expected: shows `?? .gitignore` and `?? sakila.db` as untracked. (Spec/plan files in `docs/` are already committed.)

- [ ] **Step 6: Commit**

Run:
```bash
git add .gitignore sakila.db
git commit -m "Add Sakila seed SQLite database and .gitignore

Verbatim copy of ../archive/sqlite-sakila-db/sakila.db (SQLite 3.28,
5.6 MB). This is the input to the Dockerfile /boot step that bakes
Sakila into the rqlite Raft data directory."
```

Expected: `git log -1 --oneline` shows the new commit.

---

## Task 2: Bundle the auth config

**Files:**
- Create: `auth.json`

**Goal:** A valid rqlite basic-auth config that creates the `sakila` user with full perms and (tentatively) grants unauthenticated access to `/status` and `/readyz` for health checks. This file is copied into both the builder and final image stages.

- [ ] **Step 1: Create `auth.json`**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/auth.json` with this exact content:

```json
[
  {
    "username": "sakila",
    "password": "p_ssW0rd",
    "perms": ["all"]
  },
  {
    "username": "*",
    "perms": ["status", "ready"]
  }
]
```

The wildcard entry is the unverified assumption from the spec (item 4). If the Dockerfile build in Task 3 fails at the `/readyz` poll because the wildcard doesn't work, fall back to: delete the wildcard entry, and change every healthcheck / wait loop in the project to use `-u sakila:p_ssW0rd`.

- [ ] **Step 2: Validate JSON syntax**

Run:
```bash
python3 -m json.tool auth.json >/dev/null && echo OK
```

Expected: `OK` (no JSON parse error).

- [ ] **Step 3: Commit**

Run:
```bash
git add auth.json
git commit -m "Add rqlite basic-auth config

Grants 'sakila' user full perms (password p_ssW0rd, matching the
credential convention of sibling sakiladb images). The wildcard
entry allows unauthenticated /status and /readyz so container
healthchecks and CI smoke tests don't need to embed credentials."
```

---

## Task 3: Multi-stage Dockerfile — bake Sakila into the data dir

**Files:**
- Create: `Dockerfile`

**Goal:** A multi-stage Dockerfile that builds a `sakiladb/rqlite:dev` image with Sakila preloaded into Raft. After build, `docker run`ning the image must answer authed and unauthed queries with the expected Sakila data.

**Background the implementor needs:**
- rqlite's HTTP API: `POST /boot` (chunked upload of a SQLite file, single-node only, fastest seed); `GET /readyz` (returns 200 once the node is ready); `GET /db/query?q=...` (read queries, supports `level=none|weak|strong`).
- The official `rqlite/rqlite` image's data dir is `/rqlite/file/data`. Ports are 4001 (HTTP API) and 4002 (Raft).
- `rqlited` is the daemon binary. Flags relevant here: `-node-id`, `-http-addr`, `-raft-addr`, `-http-adv-addr`, `-raft-adv-addr`, `-auth`.
- `apk add curl` is needed in the builder stage because the upstream image is Alpine-based and doesn't include curl.

- [ ] **Step 1: Write the Dockerfile**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/Dockerfile` with this exact content:

```dockerfile
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
    curl -sf -u sakila:p_ssW0rd \
        'http://localhost:4001/db/query?level=strong' \
        --data-urlencode 'q=SELECT count(*) FROM actor' \
        | grep -q '"values":\[\[200\]\]' && \
    curl -sf -u sakila:p_ssW0rd \
        'http://localhost:4001/db/query?level=strong' \
        --data-urlencode 'q=SELECT count(*) FROM film' \
        | grep -q '"values":\[\[1000\]\]' && \
    curl -sf -u sakila:p_ssW0rd \
        'http://localhost:4001/db/query?level=strong' \
        --data-urlencode 'q=SELECT count(*) FROM rental' \
        | grep -q '"values":\[\[16044\]\]' && \
    echo "Sakila baked successfully" && \
    kill -TERM "$PID" && \
    wait "$PID" 2>/dev/null || true && \
    sync

# ---- Final stage: ship the baked data dir + auth config ----
FROM rqlite/rqlite:${RQLITE_VERSION}

COPY --from=builder /rqlite/file/data /rqlite/file/data
COPY --from=builder /rqlite/auth.json /rqlite/auth.json

EXPOSE 4001 4002

CMD ["-auth=/rqlite/auth.json", \
     "-node-id=1", \
     "-http-adv-addr=rqlite1:4001", \
     "-raft-adv-addr=rqlite1:4002"]
```

Two things the implementor should NOT change without re-reading the spec:
- The `--upload-file` form of the boot call. rqlite's `/boot` requires chunked transfer encoding, which `--upload-file` provides automatically.
- The `rqlite1` advertise hostname. It's baked here intentionally so the same Raft state works in both single-node (`docker run` adds `--add-host`) and cluster (compose names the leader service `rqlite1`) modes. See spec section "Components → Dockerfile".

- [ ] **Step 2: Build the image**

Run:
```bash
docker build -t sakiladb/rqlite:dev .
```

Expected: builds successfully. The build log should include `Sakila baked successfully` near the end of the builder stage. Total build time: roughly 30–90 s depending on cache.

**If the build fails at the count assertion** → either `/boot` didn't fully ingest the data before the verify call, or the Sakila file is corrupted. Increase the `sleep 2` to `sleep 5` and rebuild. If it still fails, STOP and report.

Note: the builder stage runs *without* `-auth`, so spec assumption #4 (wildcard auth) is NOT exercised here — it only matters at runtime (Step 3 below) and in the compose healthcheck (Task 6).

- [ ] **Step 3: Run the image and smoke-test it**

Run:
```bash
docker run --rm -d --name rq-smoke -p 4001:4001 \
    --add-host rqlite1:127.0.0.1 \
    sakiladb/rqlite:dev
sleep 5
curl -sf -u sakila:p_ssW0rd 'http://localhost:4001/db/query?level=strong' \
    --data-urlencode 'q=SELECT count(*) FROM actor'
echo
curl -sf 'http://localhost:4001/readyz'
echo
```

Expected output (whitespace may vary):
```
{"results":[{"columns":["count(*)"],"types":[""],"values":[[200]]}]}
[+ok]
```

**If the unauthed `/readyz` call fails with an auth error** → spec assumption #4 is wrong. Fix: delete the wildcard entry from `auth.json`, update Task 6's compose healthcheck to use `-u sakila:p_ssW0rd`, rebuild, and re-run from Step 2. Document the fix in the commit message.

- [ ] **Step 4: Check that the baked advertise address survived a restart**

This validates spec item #2 (are advertise addresses persisted in Raft state?). Run:

```bash
curl -sf -u sakila:p_ssW0rd http://localhost:4001/status | python3 -c "import sys,json; s=json.load(sys.stdin); print('raft addr:', s['store']['raft']['transport']['local_addr']); print('http addr:', s['http']['bind_addr'])"
```

Expected: `local_addr` should reflect what's currently advertised (`rqlite1:4002`). If the path differs in this rqlite version, just `curl -sf -u sakila:p_ssW0rd http://localhost:4001/status | python3 -m json.tool | head -60` and visually confirm `rqlite1:4002` appears somewhere as the Raft address. Note the observed behavior in a code comment if anything is surprising — it'll matter in Task 6.

- [ ] **Step 5: Clean up the smoke-test container**

Run:
```bash
docker stop rq-smoke
```

Expected: container stops cleanly.

- [ ] **Step 6: Commit**

Run:
```bash
git add Dockerfile
git commit -m "Add multi-stage Dockerfile that bakes Sakila via /boot

Stage 1 starts rqlited against an empty data dir, POSTs sakila.db
to /boot, asserts the canonical row counts (actor=200, film=1000,
rental=16044), then SIGTERMs and syncs. Stage 2 copies the
resulting Raft data dir and auth.json into a fresh rqlite/rqlite
base image. Default CMD enables -auth and advertises as rqlite1
so the same baked state works in both single-node and compose
cluster modes."
```

---

## Task 4: Single-node `docker run` helper

**Files:**
- Create: `docker-run.sh`

**Goal:** A one-line helper matching the convention in sibling repos (`../postgres/docker-run.sh`, `../clickhouse/docker-run.sh`).

- [ ] **Step 1: Write the script**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/docker-run.sh` with this exact content:

```bash
#!/usr/bin/env bash

# Run the pre-built rqlite Sakila image from Docker Hub.
# --add-host makes the baked advertise hostname (rqlite1) resolve.
docker run -p 4001:4001 -p 4002:4002 \
    --add-host rqlite1:127.0.0.1 \
    -d sakiladb/rqlite:latest
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x docker-run.sh
ls -l docker-run.sh
```

Expected: `-rwxr-xr-x` (or `-rwx...`).

- [ ] **Step 3: Lint with shellcheck (optional, only if installed)**

Run:
```bash
command -v shellcheck && shellcheck docker-run.sh || echo "shellcheck not installed, skipping"
```

Expected: either shellcheck reports no issues, or it isn't installed. No issues should appear — the script is trivial.

- [ ] **Step 4: Commit**

Run:
```bash
git add docker-run.sh
git commit -m "Add docker-run.sh helper for single-node use

Matches the convention in sibling sakiladb repos. --add-host
resolves the baked rqlite1 hostname to loopback so the advertise
address still works in single-node mode."
```

---

## Task 5: README

**Files:**
- Modify: `README.md` (currently a one-line stub)

**Goal:** A README that mirrors the format of `../postgres/README.md` and documents both the single-node and compose flows.

- [ ] **Step 1: Inspect the sibling README for the canonical voice**

Run:
```bash
head -60 ../postgres/README.md
```

Use it as a stylistic reference. Keep the tone factual, short, and command-driven.

- [ ] **Step 2: Replace `README.md` with the full content**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/README.md` with this exact content:

````markdown
# sakiladb/rqlite

[rqlite](https://rqlite.io) docker image preloaded with the [Sakila](https://dev.mysql.com/doc/sakila/en/) example
database (by way of [jOOQ](https://www.jooq.org/sakila)).
See on [Docker Hub](https://hub.docker.com/r/sakiladb/rqlite).

By default these are created:

- database: `sakila` (the only database — rqlite is single-database per node)
- username / password: `sakila` / `p_ssW0rd`

## Quickstart (single node)

```shell
docker run -p 4001:4001 -p 4002:4002 \
    --add-host rqlite1:127.0.0.1 \
    -d sakiladb/rqlite:latest
```

`--add-host` is needed so the baked advertise hostname (`rqlite1`) resolves. Without it, rqlite still serves queries on `localhost:4001`, but you'll see a startup warning.

Verify:

```shell
$ curl -u sakila:p_ssW0rd \
       'http://localhost:4001/db/query?level=strong&q=SELECT+first_name,last_name+FROM+actor+LIMIT+3'
{"results":[{"columns":["first_name","last_name"],"types":["TEXT","TEXT"],
  "values":[["PENELOPE","GUINESS"],["NICK","WAHLBERG"],["ED","CHASE"]]}]}
```

The rqlite CLI also works:

```shell
$ docker run --rm -it --network host rqlite/rqlite -H localhost -P 4001 \
        --user sakila:p_ssW0rd
127.0.0.1:4001> SELECT count(*) FROM film;
+----------+
| count(*) |
+----------+
| 1000     |
+----------+
```

## 3-node cluster

A `cluster-compose.yml` is included for testing against a real Raft cluster:

```shell
docker compose -f cluster-compose.yml up -d
```

This launches three nodes:

| Service   | HTTP port | Role               |
|-----------|-----------|--------------------|
| `rqlite1` | `4001`    | Leader, has Sakila |
| `rqlite2` | `4003`    | Follower           |
| `rqlite3` | `4005`    | Follower           |

Followers boot with empty volumes and receive Sakila from the leader via Raft snapshot within a few seconds.

```shell
$ for port in 4001 4003 4005; do
    echo -n "port $port: "
    curl -s -u sakila:p_ssW0rd "http://localhost:$port/status" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['store']['raft']['state'])"
  done
port 4001: Leader
port 4003: Follower
port 4005: Follower
```

Tear down:

```shell
docker compose -f cluster-compose.yml down -v
```

## Image tags

See [Docker Hub tags](https://hub.docker.com/r/sakiladb/rqlite/tags). `:latest` tracks the latest rqlite release; semver tags (`:8`, etc.) pin to a specific rqlite major version.
````

- [ ] **Step 3: Sanity-check the README renders**

Run:
```bash
head -3 README.md
wc -l README.md
```

Expected: title line is `# sakiladb/rqlite`; the file is roughly 60–80 lines.

- [ ] **Step 4: Commit**

Run:
```bash
git add README.md
git commit -m "Replace README stub with full usage docs

Documents single-node docker run, cluster compose, smoke tests,
and image tag conventions. Follows the format of sibling sakiladb
READMEs."
```

---

## Task 6: 3-node compose cluster

**Files:**
- Create: `cluster-compose.yml`

**Goal:** A Docker Compose file that brings up three containers from the same `sakiladb/rqlite` image and forms a healthy 3-node Raft cluster with Sakila replicated to every node. Followers mount empty named volumes over `/rqlite/file/data` to mask the baked data.

**Background:**
- Compose service names become DNS names inside the default bridge network. Naming the leader `rqlite1` means it matches the baked advertise hostname.
- rqlite's join flag spelling varies by version. As of writing, `-join http://host:4001` is the canonical form. `-join-as=<username>` is used for authed clusters. Confirm via `rqlited --help | grep -i join` in the running container before assuming the spelling.

- [ ] **Step 1: Confirm the `-join-as` flag spelling**

Run:
```bash
docker run --rm sakiladb/rqlite:dev --help 2>&1 | grep -iE 'join|auth' | head -20
```

Expected: output should list a `-join` flag and one of `-join-as` or `-join-as-user` or similar. Note whichever spelling actually appears — use it in Step 2. If neither appears, see fallback at end of this task.

- [ ] **Step 2: Write the compose file**

Write `/Users/neilotoole/work/moi/sakiladb/rqlite/cluster-compose.yml` with this exact content (adjust `-join-as=sakila` if Step 1 turned up a different spelling):

```yaml
# Brings up a 3-node sakiladb/rqlite cluster.
# rqlite1 is the leader (uses the baked Sakila data dir).
# rqlite2 / rqlite3 mount empty volumes that mask the baked data,
# so they come up empty and receive Sakila via Raft snapshot from the leader.

services:
  rqlite1:
    image: sakiladb/rqlite:latest
    container_name: rqlite1
    ports:
      - "4001:4001"
      - "4002:4002"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:4001/readyz"]
      interval: 2s
      timeout: 3s
      retries: 30

  rqlite2:
    image: sakiladb/rqlite:latest
    container_name: rqlite2
    ports:
      - "4003:4001"
    volumes:
      - rqlite2_data:/rqlite/file/data
    command:
      - "-auth=/rqlite/auth.json"
      - "-node-id=2"
      - "-http-addr=0.0.0.0:4001"
      - "-raft-addr=0.0.0.0:4002"
      - "-http-adv-addr=rqlite2:4001"
      - "-raft-adv-addr=rqlite2:4002"
      - "-join=http://rqlite1:4001"
      - "-join-as=sakila"
    depends_on:
      rqlite1:
        condition: service_healthy

  rqlite3:
    image: sakiladb/rqlite:latest
    container_name: rqlite3
    ports:
      - "4005:4001"
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
    depends_on:
      rqlite1:
        condition: service_healthy

volumes:
  rqlite2_data:
  rqlite3_data:
```

The `image: sakiladb/rqlite:latest` reference resolves to the local image because `:latest` is not yet on Docker Hub. To force this, the next step builds the dev image with both tags.

- [ ] **Step 3: Tag the dev image as `:latest` for local compose use**

Run:
```bash
docker tag sakiladb/rqlite:dev sakiladb/rqlite:latest
```

- [ ] **Step 4: Bring up the cluster**

Run:
```bash
docker compose -f cluster-compose.yml up -d
sleep 15
docker compose -f cluster-compose.yml ps
```

Expected: all three services show `Up`. `rqlite1` shows `(healthy)`.

If `rqlite2` / `rqlite3` are restarting in a loop, check `docker compose -f cluster-compose.yml logs rqlite2`. Common failure modes:
- Wrong `-join-as` spelling → fix the flag and `docker compose up -d --force-recreate`.
- `/boot` left node 1 in a state that refuses joiners (spec item #1) → STOP and report; the fallback is to skip `/boot` entirely and instead use `/db/load` in Task 3, which preserves cluster joinability. This is a real spec change — surface it, don't paper over it.

- [ ] **Step 5: Verify leader / follower roles**

Run:
```bash
for port in 4001 4003 4005; do
    printf 'port %s: ' "$port"
    curl -s -u sakila:p_ssW0rd "http://localhost:$port/status" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['store']['raft']['state'])"
done
```

Expected:
```
port 4001: Leader
port 4003: Follower
port 4005: Follower
```

(The exact JSON path `store.raft.state` matches recent rqlite versions. If the path differs, `python3 -m json.tool` the full `/status` body and look for the `state` field under whatever the local Raft store is called.)

- [ ] **Step 6: Verify Sakila is queryable on every node**

Run:
```bash
for port in 4001 4003 4005; do
    printf 'port %s actor count: ' "$port"
    curl -s -u sakila:p_ssW0rd \
        "http://localhost:$port/db/query?level=strong&q=SELECT+count(*)+FROM+actor" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['values'][0][0])"
done
```

Expected:
```
port 4001 actor count: 200
port 4003 actor count: 200
port 4005 actor count: 200
```

If `level=strong` queries to a follower return an error like "not leader", drop to `level=weak` — different rqlite versions handle follower reads at strong consistency differently. Either result is acceptable for this verification as long as the row count is 200.

- [ ] **Step 7: Tear down**

Run:
```bash
docker compose -f cluster-compose.yml down -v
```

Expected: containers and named volumes are removed.

- [ ] **Step 8: Commit**

Run:
```bash
git add cluster-compose.yml
git commit -m "Add 3-node cluster compose harness

rqlite1 uses the baked /rqlite/file/data (leader, Sakila).
rqlite2/rqlite3 mount empty named volumes to mask the baked
data; they join the leader and receive Sakila via Raft snapshot.
Verified: all three nodes return actor=200."
```

---

## Task 7: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/docker-publish.yml`

**Goal:** Multi-arch (`linux/amd64`, `linux/arm64`) build and push to Docker Hub on push to `master` / `rqlite-*` branches and on `v*.*.*` tags. Cosign-signed on tag pushes. Identical structure to `../postgres/.github/workflows/docker-publish.yml`.

- [ ] **Step 1: Create the workflows directory**

Run:
```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Copy the postgres workflow as the starting point**

Run:
```bash
cp ../postgres/.github/workflows/docker-publish.yml .github/workflows/docker-publish.yml
```

- [ ] **Step 3: Retarget branch / tag triggers**

Open `.github/workflows/docker-publish.yml`. Find the top `on:` block (it looks like this in the source):

```yaml
on:
  push:
    branches: [ "master", "postgres-*" ]
    tags: [ 'v*.*.*' ]
  pull_request:
    branches: [ "master", "postgres-*" ]
```

Replace `postgres-*` with `rqlite-*` in both `branches` lists (push and pull_request). Leave `master` and the tag pattern alone. Use the `Edit` tool with `replace_all: true` and `old_string: "postgres-*"`, `new_string: "rqlite-*"`.

- [ ] **Step 4: Verify the image name resolves correctly**

The workflow uses `IMAGE_NAME: ${{ github.repository }}`, which on GitHub will be `sakiladb/rqlite`. No edit needed; just confirm by reading the file:

Run:
```bash
grep -n IMAGE_NAME .github/workflows/docker-publish.yml
```

Expected: a line like `IMAGE_NAME: ${{ github.repository }}` (unchanged from the postgres template).

- [ ] **Step 5: Sanity-check the YAML parses**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/docker-publish.yml'))" && echo OK
```

Expected: `OK`. If PyYAML isn't installed, fall back to:
```bash
python3 -c "import json,subprocess; print(subprocess.check_output(['yq','-o=json','.github/workflows/docker-publish.yml']).decode()[:80])"
```
or simply skip — the workflow only runs server-side and `actionlint` (if installed) would be the real check:
```bash
command -v actionlint && actionlint .github/workflows/docker-publish.yml || echo "actionlint not installed, skipping"
```

- [ ] **Step 6: Commit**

Run:
```bash
git add .github/workflows/docker-publish.yml
git commit -m "Add Docker publish workflow

Multi-arch (linux/amd64, linux/arm64) build + push to Docker Hub
and GHCR. Triggers on master, rqlite-* branches, and v*.*.* tags.
Cosign-signed on tag pushes. Copied from sakiladb/postgres workflow."
```

---

## Final verification

After all tasks are complete, run this end-to-end check:

- [ ] **Step 1: Rebuild from scratch to confirm reproducibility**

Run:
```bash
docker build --no-cache -t sakiladb/rqlite:dev .
```

Expected: build completes; `Sakila baked successfully` appears in the builder stage.

- [ ] **Step 2: Run the full smoke test**

Run:
```bash
./docker-run.sh
sleep 5
curl -sf -u sakila:p_ssW0rd \
    'http://localhost:4001/db/query?level=strong&q=SELECT+count(*)+FROM+actor' \
    | grep -q '\[\[200\]\]' && echo "single-node OK"
docker stop $(docker ps -q --filter ancestor=sakiladb/rqlite:latest)
```

Expected: `single-node OK`.

- [ ] **Step 3: Bring up the cluster and confirm**

Run:
```bash
docker tag sakiladb/rqlite:dev sakiladb/rqlite:latest
docker compose -f cluster-compose.yml up -d
sleep 15
for port in 4001 4003 4005; do
    curl -sf -u sakila:p_ssW0rd \
        "http://localhost:$port/db/query?level=weak&q=SELECT+count(*)+FROM+actor" \
        | grep -q '\[\[200\]\]' \
        && echo "port $port OK" || echo "port $port FAIL"
done
docker compose -f cluster-compose.yml down -v
```

Expected: three `port NNNN OK` lines.

- [ ] **Step 4: Confirm `git status` is clean**

Run:
```bash
git status
```

Expected: working tree clean.

- [ ] **Step 5: Review the commit history**

Run:
```bash
git log --oneline | head -10
```

Expected: spec commit + seven feature commits (sakila.db+gitignore, auth.json, Dockerfile, docker-run.sh, README, compose, CI workflow) on top of the initial commit.

If everything above passes, the image is ready for an `rqlite-1.0.0` branch / tag and CI handoff.
