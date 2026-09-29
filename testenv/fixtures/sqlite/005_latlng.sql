-- Locations kept the way most application tables keep them: latitude and longitude as
-- plain text columns, both numbers in one text column, and a numeric pair. Around
-- Mataram, Lombok. Rows 5-8 are what real data holds too: nothing yet, 0/0 standing in
-- for nothing, a typo, and a latitude off the earth. The map places rows 1-4 only.
DROP TABLE IF EXISTS latlng_places;
CREATE TABLE latlng_places (
    id          INTEGER PRIMARY KEY,
    nama        TEXT NOT NULL,
    latitude    TEXT,
    longitude   TEXT,
    koordinat   TEXT,
    pickup_lat  REAL,
    pickup_lng  REAL
);
INSERT INTO latlng_places (id, nama, latitude, longitude, koordinat, pickup_lat, pickup_lng) VALUES
    (1, 'Kantor Pusat',          '-8.59940239', '116.0977978', '-8.59940239, 116.0977978',       -8.5994024, 116.0977978),
    (2, 'Cabang Ampenan',        '-8.5731',     '116.0739',    '-8.5731,116.0739',               -8.5731000, 116.0739000),
    (3, 'Pelanggan Cakranegara', ' -8,5905 ',   '116,1386',    '-8,5905; 116,1386',              -8.5905000, 116.1386000),
    (4, 'Senggigi',              '-8.4906',     '116.0427',    '8°29''26"S, 116°2''34"E',        -8.4906000, 116.0427000),
    (5, 'Belum diisi',           NULL,          NULL,          NULL,                             NULL,       NULL),
    (6, 'Nol',                   '0',           '0',           '0,0',                            NULL,       NULL),
    (7, 'Salah ketik',           'n/a',         '116.1',       'Jl. Pejanggik',                  NULL,       NULL),
    (8, 'Di luar rentang',       '95.1',        '116.1',       '95.1, 116.1',                    NULL,       NULL);
