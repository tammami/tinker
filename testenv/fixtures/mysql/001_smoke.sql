-- Phase 0 smoke fixture. Idempotent. Later phases add the full fixture set (SPEC §17).
DROP TABLE IF EXISTS smoke;
CREATE TABLE smoke (
    id   INT NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
) CHARACTER SET utf8mb4;
INSERT INTO smoke (id, name) VALUES (1, 'hello'), (2, 'wörld'), (3, '日本語');
