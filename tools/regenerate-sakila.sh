#!/usr/bin/env bash
# regenerate-sakila.sh — rebuild sakila.db with a canonical SQLite Sakila schema
# (closes gh#2: NUMERIC affinity, missing AUTOINCREMENT, missing DEFAULTs).
#
# Reads existing data from $SRC and writes a fresh database at $DST.
# The embedded DDL is the source of truth; row data is copied verbatim via
# `INSERT ... SELECT * FROM src.<table>`. Indexes, triggers, and views are
# also embedded literals — if the source schema drifts, this script won't
# notice. $DST is unconditionally removed before being rebuilt.
#
# Usage:
#   tools/regenerate-sakila.sh [SRC] [DST]
# Defaults:
#   SRC = sakila.db
#   DST = sakila.db.new

set -euo pipefail

SRC="${1:-sakila.db}"
DST="${2:-sakila.db.new}"

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: source database not found: $SRC" >&2
    exit 1
fi

# A path with a single quote would break out of the ATTACH SQL literal in
# Phase 2, and would also let a hostile caller inject arbitrary statements.
# Cheap to reject up front.
if [[ "$SRC" == *\'* || "$DST" == *\'* ]]; then
    echo "ERROR: SRC and DST paths must not contain single quotes" >&2
    exit 1
fi

# Same-file would `rm -f` the source before Phase 2 attaches it.
if [[ "$SRC" -ef "$DST" ]]; then
    echo "ERROR: SRC and DST resolve to the same file: $SRC" >&2
    exit 1
fi

rm -f "$DST"

# --- Phase 1: canonical schema (tables only). Indexes/triggers/views are
# created AFTER the data load — the `*_trigger_ai` triggers rewrite
# `last_update` to NOW() on every INSERT, so creating them up front would
# clobber every copied row. ---
sqlite3 -bail "$DST" <<'SQL'
BEGIN;

CREATE TABLE actor (
  actor_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE country (
  country_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  country VARCHAR(50) NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE city (
  city_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  city VARCHAR(50) NOT NULL,
  country_id SMALLINT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_city_country FOREIGN KEY (country_id) REFERENCES country (country_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE address (
  address_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  address VARCHAR(50) NOT NULL,
  address2 VARCHAR(50) DEFAULT NULL,
  district VARCHAR(20) NOT NULL,
  city_id INT NOT NULL,
  postal_code VARCHAR(10) DEFAULT NULL,
  phone VARCHAR(20) NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_address_city FOREIGN KEY (city_id) REFERENCES city (city_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE language (
  language_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  name CHAR(20) NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE category (
  category_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  name VARCHAR(25) NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE film (
  film_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  title VARCHAR(255) NOT NULL,
  description BLOB SUB_TYPE TEXT DEFAULT NULL,
  release_year VARCHAR(4) DEFAULT NULL,
  language_id SMALLINT NOT NULL,
  original_language_id SMALLINT DEFAULT NULL,
  rental_duration SMALLINT DEFAULT 3 NOT NULL,
  rental_rate DECIMAL(4,2) DEFAULT 4.99 NOT NULL,
  length SMALLINT DEFAULT NULL,
  replacement_cost DECIMAL(5,2) DEFAULT 19.99 NOT NULL,
  rating VARCHAR(10) DEFAULT 'G',
  special_features VARCHAR(100) DEFAULT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT CHECK_special_features CHECK(special_features is null or
                                           special_features like '%Trailers%' or
                                           special_features like '%Commentaries%' or
                                           special_features like '%Deleted Scenes%' or
                                           special_features like '%Behind the Scenes%'),
  CONSTRAINT CHECK_special_rating CHECK(rating in ('G','PG','PG-13','R','NC-17')),
  CONSTRAINT fk_film_language FOREIGN KEY (language_id) REFERENCES language (language_id),
  CONSTRAINT fk_film_language_original FOREIGN KEY (original_language_id) REFERENCES language (language_id)
);

CREATE TABLE film_text (
  film_id INTEGER PRIMARY KEY NOT NULL,
  title VARCHAR(255) NOT NULL,
  description BLOB SUB_TYPE TEXT
);

CREATE TABLE staff (
  staff_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  address_id INT NOT NULL,
  picture BLOB DEFAULT NULL,
  email VARCHAR(50) DEFAULT NULL,
  store_id INT NOT NULL,
  active SMALLINT DEFAULT 1 NOT NULL,
  username VARCHAR(16) NOT NULL,
  password VARCHAR(40) DEFAULT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_staff_store FOREIGN KEY (store_id) REFERENCES store (store_id) ON DELETE NO ACTION ON UPDATE CASCADE,
  CONSTRAINT fk_staff_address FOREIGN KEY (address_id) REFERENCES address (address_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE store (
  store_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  manager_staff_id SMALLINT NOT NULL,
  address_id INT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_store_staff FOREIGN KEY (manager_staff_id) REFERENCES staff (staff_id),
  CONSTRAINT fk_store_address FOREIGN KEY (address_id) REFERENCES address (address_id)
);

CREATE TABLE customer (
  customer_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  store_id INT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  email VARCHAR(50) DEFAULT NULL,
  address_id INT NOT NULL,
  active CHAR(1) DEFAULT 'Y' NOT NULL,
  create_date TIMESTAMP NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_customer_store FOREIGN KEY (store_id) REFERENCES store (store_id) ON DELETE NO ACTION ON UPDATE CASCADE,
  CONSTRAINT fk_customer_address FOREIGN KEY (address_id) REFERENCES address (address_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE inventory (
  inventory_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  film_id INT NOT NULL,
  store_id INT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_inventory_store FOREIGN KEY (store_id) REFERENCES store (store_id) ON DELETE NO ACTION ON UPDATE CASCADE,
  CONSTRAINT fk_inventory_film FOREIGN KEY (film_id) REFERENCES film (film_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE rental (
  rental_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  rental_date TIMESTAMP NOT NULL,
  inventory_id INT NOT NULL,
  customer_id INT NOT NULL,
  return_date TIMESTAMP DEFAULT NULL,
  staff_id SMALLINT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_rental_staff FOREIGN KEY (staff_id) REFERENCES staff (staff_id),
  CONSTRAINT fk_rental_inventory FOREIGN KEY (inventory_id) REFERENCES inventory (inventory_id),
  CONSTRAINT fk_rental_customer FOREIGN KEY (customer_id) REFERENCES customer (customer_id)
);

CREATE TABLE payment (
  payment_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  customer_id INT NOT NULL,
  staff_id SMALLINT NOT NULL,
  rental_id INT DEFAULT NULL,
  amount DECIMAL(5,2) NOT NULL,
  payment_date TIMESTAMP NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_payment_rental FOREIGN KEY (rental_id) REFERENCES rental (rental_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_payment_customer FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_payment_staff FOREIGN KEY (staff_id) REFERENCES staff (staff_id)
);

CREATE TABLE film_actor (
  actor_id INT NOT NULL,
  film_id INT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (actor_id, film_id),
  CONSTRAINT fk_film_actor_actor FOREIGN KEY (actor_id) REFERENCES actor (actor_id) ON DELETE NO ACTION ON UPDATE CASCADE,
  CONSTRAINT fk_film_actor_film FOREIGN KEY (film_id) REFERENCES film (film_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

CREATE TABLE film_category (
  film_id INT NOT NULL,
  category_id SMALLINT NOT NULL,
  last_update TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (film_id, category_id),
  CONSTRAINT fk_film_category_film FOREIGN KEY (film_id) REFERENCES film (film_id) ON DELETE NO ACTION ON UPDATE CASCADE,
  CONSTRAINT fk_film_category_category FOREIGN KEY (category_id) REFERENCES category (category_id) ON DELETE NO ACTION ON UPDATE CASCADE
);

COMMIT;
SQL

# --- Phase 2: copy data from $SRC. The heredoc is unquoted so that
# $SRC expands; the path has already been rejected if it contains a
# single quote, so the SQL-string interpolation is safe. FKs are
# disabled because staff/store form a real reference cycle. ---
sqlite3 -bail "$DST" <<SQL
ATTACH DATABASE '$SRC' AS src;
PRAGMA foreign_keys = OFF;
BEGIN;

-- Parent-before-child where the dependency graph is acyclic.
-- staff <-> store is a true cycle, so we rely on FKs being OFF.
INSERT INTO country     SELECT * FROM src.country;
INSERT INTO city        SELECT * FROM src.city;
INSERT INTO address     SELECT * FROM src.address;
INSERT INTO language    SELECT * FROM src.language;
INSERT INTO category    SELECT * FROM src.category;
INSERT INTO actor       SELECT * FROM src.actor;
INSERT INTO film        SELECT * FROM src.film;
INSERT INTO film_text   SELECT * FROM src.film_text;
INSERT INTO staff       SELECT * FROM src.staff;
INSERT INTO store       SELECT * FROM src.store;
INSERT INTO customer    SELECT * FROM src.customer;
INSERT INTO inventory   SELECT * FROM src.inventory;
INSERT INTO rental      SELECT * FROM src.rental;
INSERT INTO payment     SELECT * FROM src.payment;
INSERT INTO film_actor  SELECT * FROM src.film_actor;
INSERT INTO film_category SELECT * FROM src.film_category;

COMMIT;
DETACH DATABASE src;
SQL

# --- Phase 3: indexes, triggers, views (verbatim from source) ---
sqlite3 -bail "$DST" <<'SQL'
BEGIN;

CREATE INDEX idx_actor_last_name ON actor(last_name);
CREATE INDEX idx_fk_country_id ON city(country_id);
CREATE INDEX idx_fk_city_id ON address(city_id);
CREATE INDEX idx_customer_fk_store_id ON customer(store_id);
CREATE INDEX idx_customer_fk_address_id ON customer(address_id);
CREATE INDEX idx_customer_last_name ON customer(last_name);
CREATE INDEX idx_fk_language_id ON film(language_id);
CREATE INDEX idx_fk_original_language_id ON film(original_language_id);
CREATE INDEX idx_fk_film_actor_actor ON film_actor(actor_id);
CREATE INDEX idx_fk_film_actor_film ON film_actor(film_id);
CREATE INDEX idx_fk_film_category_category ON film_category(category_id);
CREATE INDEX idx_fk_film_category_film ON film_category(film_id);
CREATE INDEX idx_fk_film_id ON inventory(film_id);
CREATE INDEX idx_fk_film_id_store_id ON inventory(store_id, film_id);
CREATE INDEX idx_fk_customer_id ON payment(customer_id);
CREATE INDEX idx_fk_staff_id ON payment(staff_id);
CREATE INDEX idx_rental_fk_customer_id ON rental(customer_id);
CREATE INDEX idx_rental_fk_inventory_id ON rental(inventory_id);
CREATE INDEX idx_rental_fk_staff_id ON rental(staff_id);
CREATE UNIQUE INDEX idx_rental_uq ON rental (rental_date, inventory_id, customer_id);
CREATE INDEX idx_fk_staff_address_id ON staff(address_id);
CREATE INDEX idx_fk_staff_store_id ON staff(store_id);
CREATE INDEX idx_fk_store_address ON store(address_id);
CREATE INDEX idx_store_fk_manager_staff_id ON store(manager_staff_id);

CREATE TRIGGER actor_trigger_ai AFTER INSERT ON actor
 BEGIN
  UPDATE actor SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER actor_trigger_au AFTER UPDATE ON actor
 BEGIN
  UPDATE actor SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER address_trigger_ai AFTER INSERT ON address
 BEGIN
  UPDATE address SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER address_trigger_au AFTER UPDATE ON address
 BEGIN
  UPDATE address SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER category_trigger_ai AFTER INSERT ON category
 BEGIN
  UPDATE category SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER category_trigger_au AFTER UPDATE ON category
 BEGIN
  UPDATE category SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER city_trigger_ai AFTER INSERT ON city
 BEGIN
  UPDATE city SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER city_trigger_au AFTER UPDATE ON city
 BEGIN
  UPDATE city SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER country_trigger_ai AFTER INSERT ON country
 BEGIN
  UPDATE country SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER country_trigger_au AFTER UPDATE ON country
 BEGIN
  UPDATE country SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER customer_trigger_ai AFTER INSERT ON customer
 BEGIN
  UPDATE customer SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER customer_trigger_au AFTER UPDATE ON customer
 BEGIN
  UPDATE customer SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_trigger_ai AFTER INSERT ON film
 BEGIN
  UPDATE film SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_trigger_au AFTER UPDATE ON film
 BEGIN
  UPDATE film SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_actor_trigger_ai AFTER INSERT ON film_actor
 BEGIN
  UPDATE film_actor SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_actor_trigger_au AFTER UPDATE ON film_actor
 BEGIN
  UPDATE film_actor SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_category_trigger_ai AFTER INSERT ON film_category
 BEGIN
  UPDATE film_category SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER film_category_trigger_au AFTER UPDATE ON film_category
 BEGIN
  UPDATE film_category SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER inventory_trigger_ai AFTER INSERT ON inventory
 BEGIN
  UPDATE inventory SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER inventory_trigger_au AFTER UPDATE ON inventory
 BEGIN
  UPDATE inventory SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER language_trigger_ai AFTER INSERT ON language
 BEGIN
  UPDATE language SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER language_trigger_au AFTER UPDATE ON language
 BEGIN
  UPDATE language SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER payment_trigger_ai AFTER INSERT ON payment
 BEGIN
  UPDATE payment SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER payment_trigger_au AFTER UPDATE ON payment
 BEGIN
  UPDATE payment SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER rental_trigger_ai AFTER INSERT ON rental
 BEGIN
  UPDATE rental SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER rental_trigger_au AFTER UPDATE ON rental
 BEGIN
  UPDATE rental SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER staff_trigger_ai AFTER INSERT ON staff
 BEGIN
  UPDATE staff SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER staff_trigger_au AFTER UPDATE ON staff
 BEGIN
  UPDATE staff SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER store_trigger_ai AFTER INSERT ON store
 BEGIN
  UPDATE store SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;
CREATE TRIGGER store_trigger_au AFTER UPDATE ON store
 BEGIN
  UPDATE store SET last_update = DATETIME('NOW')  WHERE rowid = new.rowid;
 END;

CREATE VIEW customer_list
AS
SELECT cu.customer_id AS ID,
       cu.first_name||' '||cu.last_name AS name,
       a.address AS address,
       a.postal_code AS zip_code,
       a.phone AS phone,
       city.city AS city,
       country.country AS country,
       case when cu.active=1 then 'active' else '' end AS notes,
       cu.store_id AS SID
FROM customer AS cu JOIN address AS a ON cu.address_id = a.address_id JOIN city ON a.city_id = city.city_id
    JOIN country ON city.country_id = country.country_id;

CREATE VIEW film_list
AS
SELECT film.film_id AS FID,
       film.title AS title,
       film.description AS description,
       category.name AS category,
       film.rental_rate AS price,
       film.length AS length,
       film.rating AS rating,
       actor.first_name||' '||actor.last_name AS actors
FROM category LEFT JOIN film_category ON category.category_id = film_category.category_id LEFT JOIN film ON film_category.film_id = film.film_id
        JOIN film_actor ON film.film_id = film_actor.film_id
    JOIN actor ON film_actor.actor_id = actor.actor_id;

CREATE VIEW sales_by_film_category
AS
SELECT
c.name AS category
, SUM(p.amount) AS total_sales
FROM payment AS p
INNER JOIN rental AS r ON p.rental_id = r.rental_id
INNER JOIN inventory AS i ON r.inventory_id = i.inventory_id
INNER JOIN film AS f ON i.film_id = f.film_id
INNER JOIN film_category AS fc ON f.film_id = fc.film_id
INNER JOIN category AS c ON fc.category_id = c.category_id
GROUP BY c.name;

CREATE VIEW sales_by_store
AS
SELECT
  s.store_id
 ,c.city||','||cy.country AS store
 ,m.first_name||' '||m.last_name AS manager
 ,SUM(p.amount) AS total_sales
FROM payment AS p
INNER JOIN rental AS r ON p.rental_id = r.rental_id
INNER JOIN inventory AS i ON r.inventory_id = i.inventory_id
INNER JOIN store AS s ON i.store_id = s.store_id
INNER JOIN address AS a ON s.address_id = a.address_id
INNER JOIN city AS c ON a.city_id = c.city_id
INNER JOIN country AS cy ON c.country_id = cy.country_id
INNER JOIN staff AS m ON s.manager_staff_id = m.staff_id
GROUP BY
  s.store_id
, c.city||','||cy.country
, m.first_name||' '||m.last_name;

CREATE VIEW staff_list
AS
SELECT s.staff_id AS ID,
       s.first_name||' '||s.last_name AS name,
       a.address AS address,
       a.postal_code AS zip_code,
       a.phone AS phone,
       city.city AS city,
       country.country AS country,
       s.store_id AS SID
FROM staff AS s JOIN address AS a ON s.address_id = a.address_id JOIN city ON a.city_id = city.city_id
    JOIN country ON city.country_id = country.country_id;

COMMIT;
SQL

# --- Phase 4: verify and compact ---
echo "Verifying $DST..."

# `var=$(sqlite3 ...)` does NOT trigger `set -e` on sqlite3 failure — the
# exit code disappears into the command substitution. Each capture below
# checks the exit code explicitly to avoid silently treating an open/parse
# failure as "clean".

if ! fk_check=$(sqlite3 -bail "$DST" "PRAGMA foreign_key_check;"); then
    echo "ERROR: foreign_key_check failed to run against $DST" >&2
    exit 1
fi
if [[ -n "$fk_check" ]]; then
    echo "ERROR: foreign key violations:" >&2
    echo "$fk_check" >&2
    exit 1
fi

if ! integrity=$(sqlite3 -bail "$DST" "PRAGMA integrity_check;"); then
    echo "ERROR: integrity_check failed to run against $DST" >&2
    exit 1
fi
if [[ "$integrity" != "ok" ]]; then
    echo "ERROR: integrity check failed: $integrity" >&2
    exit 1
fi

# Row-count parity vs source. List must stay in sync with the Phase 1
# CREATE TABLEs above.
for t in actor address category city country customer film film_actor film_category film_text inventory language payment rental staff store; do
    if ! src_n=$(sqlite3 -bail "$SRC" "SELECT COUNT(*) FROM $t;"); then
        echo "ERROR: failed to count $t in $SRC" >&2
        exit 1
    fi
    if ! dst_n=$(sqlite3 -bail "$DST" "SELECT COUNT(*) FROM $t;"); then
        echo "ERROR: failed to count $t in $DST" >&2
        exit 1
    fi
    if [[ "$src_n" != "$dst_n" ]]; then
        echo "ERROR: row-count mismatch in $t: src=$src_n dst=$dst_n" >&2
        exit 1
    fi
done

# View parity vs source: catches the class of mistake where Phase 3 forgets
# to recreate one of the embedded views.
if ! src_views=$(sqlite3 -bail "$SRC" "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name;"); then
    echo "ERROR: failed to list views in $SRC" >&2
    exit 1
fi
if ! dst_views=$(sqlite3 -bail "$DST" "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name;"); then
    echo "ERROR: failed to list views in $DST" >&2
    exit 1
fi
if [[ "$src_views" != "$dst_views" ]]; then
    echo "ERROR: view set differs from source" >&2
    diff <(echo "$src_views") <(echo "$dst_views") >&2 || true
    exit 1
fi

sqlite3 -bail "$DST" "VACUUM;"

echo "OK. $DST regenerated from $SRC."
echo "  size: $(wc -c < "$DST" | tr -d ' ') bytes"
