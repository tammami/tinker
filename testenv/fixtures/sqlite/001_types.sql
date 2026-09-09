-- Type coverage fixture (SPEC §17), SQLite edition. Loaded into a fresh temporary file by
-- the test suites themselves; no server, no prepare step.
DROP TABLE IF EXISTS smoke;
CREATE TABLE smoke (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL
);
INSERT INTO smoke (id, name) VALUES (1, 'hello'), (2, 'wörld'), (3, '日本語');

-- SQLite stores by affinity; the declared names below are the conventions the app
-- reads specially (BOOLEAN, DATE, DATETIME, TIME, JSON, UUID, DECIMAL) plus the five
-- storage classes.
DROP TABLE IF EXISTS all_types;
CREATE TABLE all_types (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    c_bool        BOOLEAN,
    c_int         INTEGER,
    c_bigint      BIGINT,
    c_real        REAL,
    c_double      DOUBLE PRECISION,
    c_numeric     NUMERIC(12, 4),
    c_decimal     DECIMAL(65, 30),
    c_text        TEXT,
    c_varchar     VARCHAR(255),
    c_blob        BLOB,
    c_date        DATE,
    c_time        TIME,
    c_datetime    DATETIME,
    c_timestamp   TIMESTAMP,
    c_uuid        UUID,
    c_json        JSON,
    c_any,
    c_generated   INTEGER GENERATED ALWAYS AS (c_int * 2) VIRTUAL
);

-- Row 1: ordinary values.
INSERT INTO all_types (
    c_bool, c_int, c_bigint, c_real, c_double, c_numeric, c_decimal,
    c_text, c_varchar, c_blob, c_date, c_time, c_datetime, c_timestamp,
    c_uuid, c_json, c_any
) VALUES (
    1, 2147483647, 9223372036854775807, 1.5, 2.5, 12.5, '12345678901234567890123456789012345.123456789012345678901234567890',
    'ascii text', 'varchar', X'000102ff', '2024-03-10', '02:30:00.123', '2024-03-10 02:30:00.123',
    '2024-03-10T02:30:00Z', '11111111-2222-3333-4444-555555555555', '{"a":1}', 'anything'
);

-- Row 2: NULL in every nullable column.
INSERT INTO all_types (c_bool) VALUES (NULL);

-- Row 3: extremes and Unicode.
INSERT INTO all_types (c_int, c_bigint, c_real, c_double, c_text, c_blob, c_date, c_datetime, c_any)
VALUES (
    -2147483648, -9223372036854775808, 9e999, -9e999,
    '中文 👩‍👩‍👧‍👦 אבג é',
    zeroblob(256),
    '0001-01-01', '9999-12-31 23:59:59.999', 42
);

-- Row 4: a one-megabyte string and JSON nested 50 deep.
INSERT INTO all_types (c_text, c_json) VALUES (
    (WITH RECURSIVE r(n, s) AS (SELECT 1, 'x' UNION ALL SELECT n * 2, s || s FROM r WHERE n < 1048576) SELECT s FROM r ORDER BY n DESC LIMIT 1),
    (WITH RECURSIVE j(n, s) AS (SELECT 0, '1' UNION ALL SELECT n + 1, '{"n":' || s || '}' FROM j WHERE n < 50) SELECT s FROM j ORDER BY n DESC LIMIT 1)
);

DROP TABLE IF EXISTS dst_samples;
CREATE TABLE dst_samples (
    id    INTEGER PRIMARY KEY,
    label TEXT NOT NULL,
    at    DATETIME NOT NULL
);
INSERT INTO dst_samples VALUES
    (1, 'before spring forward', '2024-03-10 01:59:59.999-05:00'),
    (2, 'after spring forward',  '2024-03-10 03:00:00-04:00'),
    (3, 'first 01:30 in fall',   '2024-11-03 01:30:00-04:00'),
    (4, 'second 01:30 in fall',  '2024-11-03 01:30:00-05:00');

-- Key shapes the grid must handle (SPEC §12.6).
DROP TABLE IF EXISTS composite_pk;
CREATE TABLE composite_pk (
    org_id  INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    role    TEXT NOT NULL DEFAULT 'member',
    PRIMARY KEY (org_id, user_id)
);
INSERT INTO composite_pk VALUES (1, 1, 'owner'), (1, 2, 'member'), (2, 1, 'admin');

DROP TABLE IF EXISTS uuid_pk;
CREATE TABLE uuid_pk (
    id    UUID PRIMARY KEY,
    label TEXT
);
INSERT INTO uuid_pk VALUES
    ('11111111-1111-1111-1111-111111111111', 'one'),
    ('22222222-2222-2222-2222-222222222222', 'two');

DROP TABLE IF EXISTS no_pk;
CREATE TABLE no_pk (a INTEGER, b TEXT);
INSERT INTO no_pk VALUES (1, 'x'), (1, 'x');

DROP TABLE IF EXISTS unique_not_null;
CREATE TABLE unique_not_null (code TEXT NOT NULL UNIQUE, payload TEXT);
INSERT INTO unique_not_null VALUES ('a', '1'), ('b', '2');

-- Relationships and derived relations.
DROP VIEW IF EXISTS customer_totals;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
CREATE TABLE customers (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    tier TEXT NOT NULL DEFAULT 'ok' CHECK (tier IN ('sad', 'ok', 'happy'))
);
CREATE TABLE orders (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL,
    total       NUMERIC(12, 2) NOT NULL DEFAULT 0,
    placed_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE CASCADE ON UPDATE RESTRICT
);
CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE UNIQUE INDEX orders_unique_customer_total ON orders (customer_id, total);
INSERT INTO customers (name, tier) VALUES ('Ada', 'happy'), ('Grace', 'ok');
INSERT INTO orders (customer_id, total) VALUES (1, 10.50), (1, 20.00), (2, 5.25);

CREATE VIEW customer_totals AS
SELECT c.id, c.name, sum(o.total) AS total
FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.id, c.name;
