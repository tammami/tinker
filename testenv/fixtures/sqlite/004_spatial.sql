-- Spatial fixture: geometry kept as text, once as hex EWKB (what PostGIS
-- itself hands over) and once as WKT, so the map viewer can be seen on a server that
-- has no extensions. Coordinates are Jakarta landmarks, WGS 84 (SRID 4326).
DROP TABLE IF EXISTS spatial_places;
CREATE TABLE spatial_places (
    id      INTEGER PRIMARY KEY,
    name    TEXT NOT NULL,
    kind    TEXT NOT NULL,
    geom    TEXT,   -- hex EWKB, SRID 4326
    shape   TEXT    -- WKT
);
INSERT INTO spatial_places (id, name, kind, geom, shape) VALUES
    (1, 'Monas', 'point', '0101000020E610000014D044D8F0B45A40A4DFBE0E9CB318C0', 'POINT(106.8272 -6.1754)'),
    (2, 'Kota Tua', 'point', '0101000020E61000008E75711B0DB45A4043AD69DE718A18C0', 'POINT(106.8133 -6.1352)'),
    (3, 'Bundaran HI', 'point', '0101000020E6100000E9263108ACB45A4048E17A14AEC718C0', 'POINT(106.823 -6.195)'),
    (4, 'Ancol', 'point', '0101000020E6100000D9CEF753E3B55A403D0AD7A3707D18C0', 'POINT(106.842 -6.1225)'),
    (5, 'Sudirman–Thamrin', 'line', NULL, 'LINESTRING(106.8230 -6.1950, 106.8215 -6.2100, 106.8095 -6.2260)'),
    (6, 'Monas park', 'polygon', NULL, 'POLYGON((106.8210 -6.1710, 106.8330 -6.1710, 106.8330 -6.1800, 106.8210 -6.1800, 106.8210 -6.1710))'),
    (7, 'Kepulauan Seribu (a few)', 'multipoint', NULL, 'MULTIPOINT((106.5900 -5.7600), (106.6100 -5.7300), (106.5700 -5.6900))'),
    (8, 'No location yet', 'point', NULL, NULL);
