-- One million rows for the data-grid performance criteria (SPEC §12.6).
-- Generated server-side, so preparing costs one statement rather than a million.
DROP TABLE IF EXISTS big_table;
CREATE TABLE big_table (
    id       integer PRIMARY KEY,
    name     text NOT NULL,
    amount   numeric(12, 2) NOT NULL,
    flag     boolean NOT NULL,
    created  timestamptz NOT NULL
);
INSERT INTO big_table (id, name, amount, flag, created)
SELECT g,
       'row ' || g,
       (g % 100000)::numeric / 100,
       g % 2 = 0,
       timestamptz '2020-01-01 00:00:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 1000000) AS g;
ANALYZE big_table;
