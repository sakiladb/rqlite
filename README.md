# sakiladb/rqlite

An [rqlite](https://rqlite.io) Docker image preloaded with the
[Sakila](https://dev.mysql.com/doc/sakila/en/) sample database (by way of
[jOOQ](https://www.jooq.org/sakila)). One of the [`sakiladb`](https://github.com/sakiladb) image
family.

These images exist primarily as test fixtures for [`sq`](https://github.com/neilotoole/sq), a
command-line tool for querying SQL databases and structured data, but they are free for anyone to
use. See sq's [driver guides](https://sq.io/docs/drivers/).

rqlite is distributed SQLite, so this variant is loaded from a SQLite [`sakila.db`](sakila.db) baked
into the image and served over rqlite's HTTP API.

Available on [Docker Hub](https://hub.docker.com/r/sakiladb/rqlite) and
[GitHub Container Registry](https://github.com/sakiladb/rqlite/pkgs/container/rqlite).

## Quick start

```shell
docker run -p 4001:4001 -p 4002:4002 \
    --add-host rqlite1:127.0.0.1 \
    -d sakiladb/rqlite:latest
```

The Sakila data is baked into the image, so there is no initialization step at startup; the
container is ready in a few seconds. `--add-host rqlite1:127.0.0.1` makes the baked advertise
hostname (`rqlite1`) resolve inside the container; without it rqlite still serves on `localhost:4001`
but logs a startup warning.

The image declares a Docker
[`HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck), so you can wait for
readiness rather than guessing. Its status becomes `healthy` once the node is ready to serve:

```shell
docker run -p 4001:4001 -p 4002:4002 --add-host rqlite1:127.0.0.1 \
    -d --name sakila sakiladb/rqlite:latest
until [ "$(docker inspect -f '{{.State.Health.Status}}' sakila)" = healthy ]; do sleep 1; done
```

In Docker Compose, gate dependents with `depends_on: { condition: service_healthy }`.

When you are done, remove the container (`docker rm -f sakila` for the named form above, or
`docker rm -f $(docker ps -q --filter ancestor=sakiladb/rqlite:latest)` for the unnamed Quick-start
container).

> [!TIP]
> Building or testing on GitHub Actions? Pull from GHCR (`ghcr.io/sakiladb/rqlite`). Docker Hub
> rate-limits pulls and CI runners share IP addresses, so the limit is reached quickly; GHCR isn't
> throttled the same way, especially from within GitHub's network.

## Connection

| Setting   | Value       |
|-----------|-------------|
| host      | `localhost` |
| HTTP port | `4001`      |
| Raft port | `4002`      |
| database  | `sakila`    |
| user      | `sakila`    |
| password  | `p_ssW0rd`  |

The rqlite HTTP API is reachable directly with `curl`:

```shell
$ curl -u sakila:p_ssW0rd \
       'http://localhost:4001/db/query?level=strong&q=SELECT+first_name,last_name+FROM+actor+LIMIT+3'
{"results":[{"columns":["first_name","last_name"],"types":["TEXT","TEXT"],
  "values":[["PENELOPE","GUINESS"],["NICK","WAHLBERG"],["ED","CHASE"]]}]}
```

With [`sq`](https://github.com/neilotoole/sq) ([install](https://sq.io/docs/install)), use the
`rqlite://` scheme. Because this is a single node advertising a container-internal hostname
(`rqlite1`), add `?disableClusterDiscovery=true` so the client talks to the published port directly.
The flag is specific to this single-node-on-Docker topology, not a requirement of the driver: a real
multi-node cluster whose peer hostnames are resolvable from the client leaves discovery on (the
default) so leader redirects and failover work automatically.

```shell
$ sq add 'rqlite://sakila:p_ssW0rd@localhost:4001?disableClusterDiscovery=true' --handle @sakila_rq
@sakila_rq  rqlite  sakila@localhost:4001

$ sq '@sakila_rq.actor | .[0:5]'
actor_id  first_name  last_name     last_update
1         PENELOPE    GUINESS       2006-02-15T04:34:33Z
2         NICK        WAHLBERG      2006-02-15T04:34:33Z
3         ED          CHASE         2006-02-15T04:34:33Z
4         JENNIFER    DAVIS         2006-02-15T04:34:33Z
5         JOHNNY      LOLLOBRIGIDA  2006-02-15T04:34:33Z
```

The [rqlite CLI](https://rqlite.io/docs/cli/) also works. Install it natively (`brew install rqlite`
on macOS) and run it against the published port; it defaults to `127.0.0.1:4001`, so no flags are
needed beyond the credentials:

```shell
$ rqlite --user sakila:p_ssW0rd
127.0.0.1:4001> SELECT count(*) FROM film;
+----------+
| count(*) |
+----------+
| 1000     |
+----------+
```

To run the CLI from the `rqlite/rqlite` image instead of installing it, override the entrypoint (the
image's default entrypoint is the *server*). On Docker Desktop or Colima (macOS), reach the published
port via `host.docker.internal`, **not** `--network host`, which on macOS attaches to the Docker VM
rather than your laptop (on Linux, `--network host` with `-H localhost` works):

```shell
docker run --rm -i --entrypoint rqlite rqlite/rqlite \
    -H host.docker.internal -p 4001 --user sakila:p_ssW0rd
```

## What's inside

The standard Sakila sample database: **16 tables and 7 views**, owned by the `sakila` user. It is the
same SQLite dataset the [`sqlite`/`duckdb` file fixtures](https://github.com/sakiladb) derive from, so
the object set, row counts, and data match the rest of the family.

[`sq inspect`](https://sq.io/docs/inspect) shows the whole schema (tables, views, row counts, and
columns) at a glance:

```shell
$ sq inspect @sakila_rq
SOURCE      DRIVER  NAME  FQ NAME  SIZE  TABLES  VIEWS  LOCATION
@sakila_rq  rqlite  main  main     -     16      7      rqlite://sakila:xxxxx@localhost:4001?disableClusterDiscovery=true

NAME                        TYPE   ROWS   COLS
actor                       table  200    actor_id, first_name, last_name, last_update
address                     table  603    address_id, address, address2, district, city_id, postal_code, phone, last_update
category                    table  16     category_id, name, last_update
city                        table  600    city_id, city, country_id, last_update
country                     table  109    country_id, country, last_update
customer                    table  599    customer_id, store_id, first_name, last_name, email, address_id, active, create_date, last_update
film                        table  1000   film_id, title, description, release_year, language_id, original_language_id, rental_duration, rental_rate, length, replacement_cost, rating, special_features, last_update
film_actor                  table  5462   actor_id, film_id, last_update
film_category               table  1000   film_id, category_id, last_update
film_text                   table  1000   film_id, title, description
inventory                   table  4581   inventory_id, film_id, store_id, last_update
language                    table  6      language_id, name, last_update
payment                     table  16049  payment_id, customer_id, staff_id, rental_id, amount, payment_date, last_update
rental                      table  16044  rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update
staff                       table  2      staff_id, first_name, last_name, address_id, picture, email, store_id, active, username, password, last_update
store                       table  2      store_id, manager_staff_id, address_id, last_update
actor_info                  view   200    actor_id, first_name, last_name, film_info
customer_list               view   599    ID, name, address, zip code, phone, city, country, notes, SID
film_list                   view   997    FID, title, description, category, price, length, rating, actors
nicer_but_slower_film_list  view   997    FID, title, description, category, price, length, rating, actors
sales_by_film_category      view   16     category, total_sales
sales_by_store              view   2      store, manager, total_sales
staff_list                  view   2      ID, name, address, zip code, phone, city, country, SID
```

## Differences from other sakila variants

The object set and row data match the family, but rqlite is distributed SQLite, so a few engine
traits differ:

- **`sq` uses the rqlite driver.** `sq inspect` reports `DRIVER: rqlite`. Reaching the single-node
  image from the host needs `?disableClusterDiscovery=true`, because the node advertises a
  container-internal hostname (`rqlite1`) the host cannot resolve. That is a trait of this single-node
  Docker setup, not the driver: a real multi-node cluster with host-resolvable peers leaves discovery
  on (the default) for leader redirects and failover.
- **`film_text` is a plain table** (populated from `film`). SQLite full-text search needs an FTS5
  virtual table, which is schema-visible and would push the count past 16, so (like the `sqlite`,
  `duckdb`, and `oracle` variants) full-text search is omitted for parity.
- **`sales_by_film_category` / `sales_by_store` totals format differently.** SQLite sums the
  `DECIMAL` amounts in floating point, so the totals differ in presentation from the `NUMERIC`-exact
  engines (e.g. `4656.3` vs `4656.30`). This is intrinsic to SQLite and is shared identically by the
  `sqlite` and `duckdb` fixtures.
- **Single database per node.** rqlite serves one database (`sakila`); there is no concept of
  multiple schemas or databases on a node.
- **`address` has no `location` column** (the spatial `GEOMETRY` column upstream MySQL Sakila ships is
  dropped across the whole family).

## Available versions

Each rqlite major version is published as its own image tag. `latest` tracks the newest version
(currently 10).

| rqlite | sakiladb Release | Architecture     | Docker Hub                       | GitHub Container Registry                |
|--------|------------------|------------------|----------------------------------|------------------------------------------|
| 10     | `v10.0.13`       | `amd64`, `arm64` | [`sakiladb/rqlite:10`](https://hub.docker.com/r/sakiladb/rqlite), [`:latest`](https://hub.docker.com/r/sakiladb/rqlite) | [`ghcr.io/sakiladb/rqlite:10`](https://github.com/sakiladb/rqlite/pkgs/container/rqlite), [`:latest`](https://github.com/sakiladb/rqlite/pkgs/container/rqlite) |

The image tag tracks the **rqlite major version**. **sakiladb Release** is the git tag the current
image was built from (see [releases](https://github.com/sakiladb/rqlite/releases)); the version is
`v{MAJOR}.{MINOR}.{PATCH}` with the **major** tracking rqlite (`ARG RQLITE_VERSION`, currently
`10.2.0`) and the **minor**/**patch** tracking sakiladb's own revisions (so successive `v10.x.y`
releases all surface as `:10`). Every version is published to both
[Docker Hub](https://hub.docker.com/r/sakiladb/rqlite) and
[GitHub Container Registry](https://github.com/sakiladb/rqlite/pkgs/container/rqlite), built for
`amd64` + `arm64`, and signed with [cosign](https://github.com/sigstore/cosign). Each image also
carries [SLSA build provenance](https://slsa.dev/) and an SPDX [SBOM](https://spdx.dev/) attestation
(verify with `gh attestation verify`).

## Running a 3-node cluster

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

Followers boot with empty volumes and receive Sakila from the leader via Raft snapshot within a few
seconds. Each node's role can be polled directly on its own port:

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

### Querying the cluster from your host

Every node's HTTP port is published, so you can query any node directly from your laptop. Point your
client at the node's port and disable cluster discovery:

```shell
# the leader (reads + writes), on 4001
sq add 'rqlite://sakila:p_ssW0rd@localhost:4001?disableClusterDiscovery=true' --handle @rq_leader

# a follower (reads), on 4003
sq add 'rqlite://sakila:p_ssW0rd@localhost:4003?disableClusterDiscovery=true' --handle @rq_follower
```

> **Why `disableClusterDiscovery`, and what this means on macOS.** Left to discover the cluster, a
> client follows rqlite's leader-redirect to each node's *advertised* address (`rqlite1`, `rqlite2`,
> ...). Those names resolve inside the Docker network but not from your host, so discovery fails with
> `advertised peer "rqlite1" is not resolvable from this host`. This is true on every OS: Docker
> Desktop and Colima on macOS don't change it, and `--network host` won't help (on macOS it attaches
> to the Docker VM, not your laptop). Disabling discovery makes the client talk to the published port
> directly, which is all you need to query the fixture.
>
> To exercise the *real* discovery + leader-redirect path locally, run a **native** cluster instead of
> the Docker one: rqlite's [`sakila-start-rqlite-cluster.sh`](https://github.com/neilotoole/sq/blob/master/drivers/rqlite/sakila-start-rqlite-cluster.sh)
> (`brew install rqlite`) starts three nodes bound to `127.0.0.1`, so discovery returns
> host-reachable addresses and `sq` connects without `disableClusterDiscovery`.

Tear down:

```shell
docker compose -f cluster-compose.yml down -v
```

## Releasing a new version

Maintainers: releases are tag-driven. Pushing a semver tag `vN.x.y` builds and publishes that rqlite
major version; the version is derived from the tag, so there are no per-version branches. See
[CLAUDE.md](./CLAUDE.md) for the full, repeatable procedure.

## Changelog

### 2026-06-30

- **Supply-chain attestations** (`v10.0.13`): published images now carry
  [SLSA build provenance](https://slsa.dev/) and an SPDX [SBOM](https://spdx.dev/)
  attestation, alongside the existing cosign signature (pushed to Docker Hub and
  GHCR as OCI referrers and to GitHub's attestation store; verify with
  `gh attestation verify`). Each release also self-verifies its attestations. The
  dataset and schema are unchanged.

### 2026-06-28

- **macOS-actionable docs** (`v10.0.12`): reworked the CLI and cluster guidance for Docker Desktop /
  Colima (native `brew install rqlite`, a `host.docker.internal` form for the dockerized CLI, and
  querying the cluster from the host with `disableClusterDiscovery`). The Sakila dataset and schema
  are unchanged.
- **Aligned two views with the canonical Sakila.** `sales_by_store` no longer carries a stray leading
  `store_id` column (it is now `store, manager, total_sales`), and `customer_list` / `staff_list` use
  the canonical `zip code` alias (was `zip_code`). The column set is now in exact parity with the rest
  of the family.
- **CI hardening**: registry login is gated on release, third-party actions are SHA-pinned, and
  Dependabot keeps the GitHub Actions current.

### 2026-06-26

- **Restored faithful original Sakila data**: the Unicode accents, phone numbers, districts, and
  `last_update` timestamps now match the canonical MySQL Sakila byte for byte.

### 2026-06-25

- **Published to GitHub Container Registry** (`ghcr.io/sakiladb/rqlite`) alongside Docker Hub.
- **Reconciled to the consistent sakiladb fixture: 16 tables + 7 views.** `film_text` is added as a
  plain table and the aggregating views (`film_list`, `nicer_but_slower_film_list`, `actor_info`) use
  deterministic `group_concat(... ORDER BY ...)` so their output matches the other variants.

### 2026-06-23

- **Hardened the data bake**: the baked data dir lives outside the base image's inherited `VOLUME`,
  and the build re-verifies a fresh node from the persisted dir before publishing (fixes a
  previously empty published image).

## License

[MIT](./LICENSE).
