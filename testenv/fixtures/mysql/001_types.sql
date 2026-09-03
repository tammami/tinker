-- Type coverage fixture, mirroring the PostgreSQL one in intent (SPEC §17).
DROP TABLE IF EXISTS smoke;
CREATE TABLE smoke (
    id   INT NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
) CHARACTER SET utf8mb4;
INSERT INTO smoke (id, name) VALUES (1, 'hello'), (2, 'wörld'), (3, '日本語');

DROP TABLE IF EXISTS all_types;
CREATE TABLE all_types (
    id             INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    c_bool         TINYINT(1),
    c_tinyint      TINYINT,
    c_utinyint     TINYINT UNSIGNED,
    c_smallint     SMALLINT,
    c_mediumint    MEDIUMINT,
    c_int          INT,
    c_bigint       BIGINT,
    c_ubigint      BIGINT UNSIGNED,
    c_float        FLOAT,
    c_double       DOUBLE,
    c_decimal      DECIMAL(65, 30),
    c_char         CHAR(8),
    c_varchar      VARCHAR(255),
    c_text         LONGTEXT,
    c_binary       BINARY(4),
    c_varbinary    VARBINARY(255),
    c_blob         LONGBLOB,
    c_date         DATE,
    c_time         TIME(6),
    c_datetime     DATETIME(6),
    c_timestamp    TIMESTAMP(6) NULL,
    c_year         YEAR,
    c_json         JSON,
    c_enum         ENUM('sad', 'ok', 'happy'),
    c_set          SET('a', 'b', 'c'),
    c_bit          BIT(8),
    c_generated    BIGINT GENERATED ALWAYS AS (c_int * 2) STORED
) CHARACTER SET utf8mb4;
ALTER TABLE all_types COMMENT = 'Every mapped MySQL type, plus NULLs and extremes';

-- Row 1: ordinary values.
INSERT INTO all_types (
    c_bool, c_tinyint, c_utinyint, c_smallint, c_mediumint, c_int, c_bigint, c_ubigint,
    c_float, c_double, c_decimal,
    c_char, c_varchar, c_text, c_binary, c_varbinary, c_blob,
    c_date, c_time, c_datetime, c_timestamp, c_year,
    c_json, c_enum, c_set, c_bit
) VALUES (
    1, 127, 255, 32767, 8388607, 2147483647, 9223372036854775807, 18446744073709551615,
    1.5, 2.5, '12345678901234567890123456789012345.123456789012345678901234567890',
    'char8   ', 'varchar', 'ascii text', X'000102FF', X'00FF', X'DEADBEEF',
    '2024-03-10', '02:30:00.123456', '2024-03-10 02:30:00.123456', '2024-03-10 02:30:00.123456', 2024,
    '{"b": [1, 2, 3]}', 'happy', 'a,c', b'10110001'
);

-- Row 2: NULL in every nullable column.
INSERT INTO all_types (c_bool) VALUES (NULL);

-- Row 3: extremes and Unicode.
INSERT INTO all_types (
    c_tinyint, c_smallint, c_int, c_bigint, c_float, c_double, c_decimal,
    c_text, c_blob, c_date, c_datetime
) VALUES (
    -128, -32768, -2147483648, -9223372036854775808, -1.5, -2.5,
    '-0.000000000000000000000000000001',
    -- CJK, an emoji ZWJ sequence, RTL, and a combining sequence.
    CONCAT('中文 ', '👩‍👩‍👧‍👦', ' ', 'אבג', ' é'),
    UNHEX(REPEAT('00', 1)), '1000-01-01', '9999-12-31 23:59:59.999999'
);

-- Row 4: a one-megabyte string and JSON nested 50 deep.
INSERT INTO all_types (c_text, c_json) VALUES (
    REPEAT('x', 1048576),
    CAST(CONCAT(REPEAT('{"n":', 50), '1', REPEAT('}', 50)) AS JSON)
);

-- Every byte value, written in one go so nothing is lost in escaping.
UPDATE all_types SET c_blob = UNHEX((
    SELECT GROUP_CONCAT(LPAD(HEX(n), 2, '0') ORDER BY n SEPARATOR '')
    FROM (
        SELECT (a.d + b.d * 16) AS n
        FROM (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
              UNION SELECT 10 UNION SELECT 11 UNION SELECT 12 UNION SELECT 13
              UNION SELECT 14 UNION SELECT 15) a
        CROSS JOIN (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
              UNION SELECT 10 UNION SELECT 11 UNION SELECT 12 UNION SELECT 13
              UNION SELECT 14 UNION SELECT 15) b
    ) bytes
)) WHERE id = 3;

-- Key shapes the grid must handle (SPEC §12.6).
DROP TABLE IF EXISTS composite_pk;
CREATE TABLE composite_pk (
    org_id  INT NOT NULL,
    user_id INT NOT NULL,
    role    VARCHAR(50) NOT NULL DEFAULT 'member',
    PRIMARY KEY (org_id, user_id)
) CHARACTER SET utf8mb4;
INSERT INTO composite_pk VALUES (1, 1, 'owner'), (1, 2, 'member'), (2, 1, 'admin');

DROP TABLE IF EXISTS uuid_pk;
CREATE TABLE uuid_pk (
    id    CHAR(36) NOT NULL PRIMARY KEY,
    label VARCHAR(50)
) CHARACTER SET utf8mb4;
INSERT INTO uuid_pk VALUES
    ('11111111-1111-1111-1111-111111111111', 'one'),
    ('22222222-2222-2222-2222-222222222222', 'two');

DROP TABLE IF EXISTS no_pk;
CREATE TABLE no_pk (a INT, b VARCHAR(50)) CHARACTER SET utf8mb4;
INSERT INTO no_pk VALUES (1, 'x'), (1, 'x');

DROP TABLE IF EXISTS unique_not_null;
CREATE TABLE unique_not_null (
    code    VARCHAR(50) NOT NULL UNIQUE,
    payload VARCHAR(50)
) CHARACTER SET utf8mb4;
INSERT INTO unique_not_null VALUES ('a', '1'), ('b', '2');

-- Relationships and a view.
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
CREATE TABLE customers (
    id   INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    tier ENUM('sad', 'ok', 'happy') NOT NULL DEFAULT 'ok'
) CHARACTER SET utf8mb4;
CREATE TABLE orders (
    id          INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    total       DECIMAL(12, 2) NOT NULL DEFAULT 0,
    placed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE CASCADE ON UPDATE RESTRICT
) CHARACTER SET utf8mb4;
CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE UNIQUE INDEX orders_unique_customer_total ON orders (customer_id, total);
INSERT INTO customers (name, tier) VALUES ('Ada', 'happy'), ('Grace', 'ok');
INSERT INTO orders (customer_id, total) VALUES (1, 10.50), (1, 20.00), (2, 5.25);

DROP VIEW IF EXISTS customer_totals;
CREATE VIEW customer_totals AS
SELECT c.id, c.name, SUM(o.total) AS total
FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.id, c.name;

DROP FUNCTION IF EXISTS add_numbers;
CREATE FUNCTION add_numbers(a INT, b INT) RETURNS INT DETERMINISTIC RETURN a + b;

DROP PROCEDURE IF EXISTS touch_customer;
CREATE PROCEDURE touch_customer(IN cid INT)
    UPDATE customers SET name = name WHERE id = cid;
