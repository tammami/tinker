-- One million rows for the data-grid performance criteria (SPEC §12.6), generated
-- server-side with a recursive CTE so preparing costs one statement.
DROP TABLE IF EXISTS big_table;
CREATE TABLE big_table (
    id      INT NOT NULL PRIMARY KEY,
    name    VARCHAR(100) NOT NULL,
    amount  DECIMAL(12, 2) NOT NULL,
    flag    TINYINT(1) NOT NULL,
    created DATETIME NOT NULL
) CHARACTER SET utf8mb4;

SET SESSION cte_max_recursion_depth = 1000000;
INSERT INTO big_table (id, name, amount, flag, created)
WITH RECURSIVE series (n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM series WHERE n < 1000000
)
SELECT n,
       CONCAT('row ', n),
       (n % 100000) / 100,
       n % 2 = 0,
       TIMESTAMPADD(SECOND, n, '2020-01-01 00:00:00')
FROM series;
ANALYZE TABLE big_table;
