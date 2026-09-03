-- Objects the table designer reads: check constraints, triggers and partitioning
-- (SPEC §8, §15b). CHECK constraints need MySQL 8.0.16 or MariaDB 10.2; on anything
-- older the server parses and discards them, and the introspector reports none.

DROP TABLE IF EXISTS checked_values;
CREATE TABLE checked_values (
    id       int PRIMARY KEY,
    quantity int NOT NULL,
    label    varchar(64),
    CONSTRAINT quantity_positive CHECK (quantity > 0),
    CONSTRAINT label_not_blank CHECK (label IS NULL OR CHAR_LENGTH(label) > 0)
) ENGINE = InnoDB;

DROP TABLE IF EXISTS audited;
CREATE TABLE audited (
    id      int PRIMARY KEY,
    touched int NOT NULL DEFAULT 0
) ENGINE = InnoDB;

DROP TRIGGER IF EXISTS audited_bump;
CREATE TRIGGER audited_bump
    BEFORE UPDATE ON audited
    FOR EACH ROW
    SET NEW.touched = OLD.touched + 1;

DROP TABLE IF EXISTS measurements;
CREATE TABLE measurements (
    id       int NOT NULL,
    taken_at date NOT NULL,
    reading  decimal(10,2),
    PRIMARY KEY (id, taken_at)
) ENGINE = InnoDB
PARTITION BY RANGE (YEAR(taken_at)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026)
);
