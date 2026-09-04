-- Spatial fixture on MySQL's own geometry types, SRID 4326. MySQL writes WGS 84 with
-- latitude first, which is why the WKT below reads (lat lon). The same Jakarta landmarks
-- as the PostgreSQL fixture, so the map viewer shows the same picture on both.
DROP TABLE IF EXISTS spatial_places;
CREATE TABLE spatial_places (
    id      INT PRIMARY KEY,
    name    VARCHAR(80) NOT NULL,
    kind    VARCHAR(20) NOT NULL,
    geom    GEOMETRY SRID 4326 NULL,
    note    VARCHAR(120) NULL
) ENGINE=InnoDB;
INSERT INTO spatial_places (id, name, kind, geom, note) VALUES
    (1, 'Monas',            'point',   ST_GeomFromText('POINT(-6.1754 106.8272)', 4326), 'National Monument'),
    (2, 'Kota Tua',         'point',   ST_GeomFromText('POINT(-6.1352 106.8133)', 4326), 'Old town square'),
    (3, 'Bundaran HI',      'point',   ST_GeomFromText('POINT(-6.1950 106.8230)', 4326), NULL),
    (4, 'Ancol',            'point',   ST_GeomFromText('POINT(-6.1225 106.8420)', 4326), 'Waterfront'),
    (5, 'Sudirman–Thamrin', 'line',    ST_GeomFromText('LINESTRING(-6.1950 106.8230, -6.2100 106.8215, -6.2260 106.8095)', 4326), 'Main avenue'),
    (6, 'Monas park',       'polygon', ST_GeomFromText('POLYGON((-6.1710 106.8210, -6.1710 106.8330, -6.1800 106.8330, -6.1800 106.8210, -6.1710 106.8210))', 4326), NULL),
    (7, 'No location yet',  'point',   NULL, 'A row without a geometry');
