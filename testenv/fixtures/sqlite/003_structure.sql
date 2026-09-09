-- Objects the table designer reads: check constraints and triggers (SPEC §8, §15b).
-- SQLite has no partitioning, so there is no `measurements` here.
DROP TABLE IF EXISTS checked_values;
CREATE TABLE checked_values (
    id       INTEGER PRIMARY KEY,
    quantity INTEGER NOT NULL,
    label    TEXT,
    CONSTRAINT quantity_positive CHECK (quantity > 0),
    CONSTRAINT label_not_blank CHECK (label IS NULL OR length(label) > 0)
);

DROP TABLE IF EXISTS audited;
CREATE TABLE audited (
    id      INTEGER PRIMARY KEY,
    touched INTEGER NOT NULL DEFAULT 0
);

CREATE TRIGGER audited_bump
    BEFORE UPDATE ON audited
    FOR EACH ROW
    WHEN (OLD.id IS NOT NULL)
BEGIN
    UPDATE audited SET touched = COALESCE(OLD.touched, 0) + 1 WHERE id = NEW.id;
END;
