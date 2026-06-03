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
