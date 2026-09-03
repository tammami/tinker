-- Objects the table designer reads: check constraints, triggers and partitioning
-- (SPEC §8, §15b). Kept apart from 001_types.sql so the type round-trip fixtures stay
-- about types.

DROP TABLE IF EXISTS checked_values CASCADE;
CREATE TABLE checked_values (
    id       integer PRIMARY KEY,
    quantity integer NOT NULL,
    label    text,
    CONSTRAINT quantity_positive CHECK (quantity > 0),
    CONSTRAINT label_not_blank CHECK (label IS NULL OR length(label) > 0)
);

DROP TABLE IF EXISTS audited CASCADE;
CREATE TABLE audited (
    id      integer PRIMARY KEY,
    touched integer NOT NULL DEFAULT 0
);

CREATE OR REPLACE FUNCTION bump_touched() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.touched := COALESCE(OLD.touched, 0) + 1;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audited_bump ON audited;
CREATE TRIGGER audited_bump
    BEFORE UPDATE ON audited
    FOR EACH ROW
    WHEN (OLD.id IS NOT NULL)
    EXECUTE FUNCTION bump_touched();

DROP TABLE IF EXISTS measurements CASCADE;
CREATE TABLE measurements (
    id       integer NOT NULL,
    taken_at date    NOT NULL,
    reading  numeric(10,2)
) PARTITION BY RANGE (taken_at);

CREATE TABLE measurements_2024 PARTITION OF measurements
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE measurements_2025 PARTITION OF measurements
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
