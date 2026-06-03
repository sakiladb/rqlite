#!/usr/bin/env bash

# Run the pre-built rqlite Sakila image from Docker Hub.
# --add-host makes the baked advertise hostname (rqlite1) resolve.
docker run -p 4001:4001 -p 4002:4002 \
    --add-host rqlite1:127.0.0.1 \
    -d sakiladb/rqlite:latest
