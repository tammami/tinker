import DBCore
import Foundation
import XCTest

@testable import DBGrid

final class CoordinatesTests: XCTestCase {
    // MARK: - Numbers

    func testPlainNumbersToleratePaddingAndADecimalComma() throws {
        XCTAssertEqual(CoordinateText.number("-8.59940239"), -8.59940239)
        XCTAssertEqual(CoordinateText.number("  116.0977978 \n"), 116.0977978)
        XCTAssertEqual(CoordinateText.number("+116.1"), 116.1)
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("-8,5994")), -8.5994, accuracy: 1e-12)
        // A comma next to a dot is a thousands separator, not a coordinate.
        XCTAssertNil(CoordinateText.number("1,116.09"))
        XCTAssertNil(CoordinateText.number("1,2,3"))
        for junk in ["", " ", "n/a", "-", "NaN", "inf", "1e5", "12abc", "—"] {
            XCTAssertNil(CoordinateText.number(junk), junk)
        }
    }

    func testDegreesMinutesSecondsWithHemispheres() throws {
        let south = try XCTUnwrap(CoordinateText.number("8°35'57.8\"S"))
        XCTAssertEqual(south, -(8 + 35.0 / 60 + 57.8 / 3_600), accuracy: 1e-9)
        let east = try XCTUnwrap(CoordinateText.number("116° 5′ 52″ E"))
        XCTAssertEqual(east, 116 + 5.0 / 60 + 52.0 / 3_600, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("S 8° 35.5'")), -(8 + 35.5 / 60), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("-8°30'")), -8.5, accuracy: 1e-9)
        // Indonesian hemispheres: lintang selatan, bujur timur, bujur barat.
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("8,5 LS")), -8.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("116.1 BT")), 116.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CoordinateText.number("10 BB")), -10, accuracy: 1e-9)
        // Without a degree sign or a hemisphere, three numbers are not a coordinate.
        XCTAssertNil(CoordinateText.number("8 35 57"))
        // Minutes and seconds stop at sixty.
        XCTAssertNil(CoordinateText.number("8°75'S"))
    }

    func testPairsInOneTextColumn() throws {
        func pair(_ text: String) -> [Double]? { CoordinateText.pair(text).map { [$0.first, $0.second] } }
        XCTAssertEqual(pair("-8.5994,116.0977"), [-8.5994, 116.0977])
        XCTAssertEqual(pair(" -8.5994, 116.0977 "), [-8.5994, 116.0977])
        XCTAssertEqual(pair("-8,5994; 116,0977"), [-8.5994, 116.0977])
        XCTAssertEqual(pair("-8,5994, 116,0977"), [-8.5994, 116.0977])
        XCTAssertEqual(pair("-8.5994 116.0977"), [-8.5994, 116.0977])
        XCTAssertEqual(pair("(-8.5994, 116.0977)"), [-8.5994, 116.0977])
        XCTAssertEqual(pair("[116.0977,-8.5994]"), [116.0977, -8.5994])
        let dms = try XCTUnwrap(pair("8°35'57.8\"S, 116°5'52\"E"))
        XCTAssertEqual(dms[0], -8.599389, accuracy: 1e-6)
        XCTAssertEqual(dms[1], 116.097778, accuracy: 1e-6)
        XCTAssertNil(pair("-8.5994"))
        XCTAssertNil(pair("Jl. Pejanggik No. 10, Mataram"))
        XCTAssertNil(pair("1, 2, 3"))
    }

    func testValueTextSkipsNullBlankAndNonNumericKinds() {
        XCTAssertNil(CoordinateText.text(of: nil))
        XCTAssertNil(CoordinateText.text(of: .null))
        XCTAssertNil(CoordinateText.text(of: .string("   ")))
        XCTAssertNil(CoordinateText.text(of: .string("NULL")))
        XCTAssertNil(CoordinateText.text(of: .bool(true)))
        XCTAssertEqual(CoordinateText.text(of: .decimal("-8.5956962157580")), "-8.5956962157580")
        XCTAssertEqual(CoordinateText.text(of: .double(116.5)), "116.5")
        XCTAssertEqual(CoordinateText.text(of: .string(" -8.59 ")), "-8.59")
    }

    // MARK: - Names

    func testColumnNamesClaimAnAxisAndAPairingKey() {
        func axis(_ name: String) -> String? {
            CoordinateNames.axis(of: name).map { "\($0.axis == .latitude ? "lat" : "lng"):\($0.key)" }
        }
        XCTAssertEqual(axis("latitude"), "lat:")
        XCTAssertEqual(axis("lattitude"), "lat:")
        XCTAssertEqual(axis("Latitude"), "lat:")
        XCTAssertEqual(axis("LAT"), "lat:")
        XCTAssertEqual(axis("lintang"), "lat:")
        XCTAssertEqual(axis("longitude"), "lng:")
        XCTAssertEqual(axis("longtitude"), "lng:")
        XCTAssertEqual(axis("lng"), "lng:")
        XCTAssertEqual(axis("lon"), "lng:")
        XCTAssertEqual(axis("long"), "lng:")
        XCTAssertEqual(axis("bujur"), "lng:")
        XCTAssertEqual(axis("pickup_lat"), "lat:pickup")
        XCTAssertEqual(axis("pickupLng"), "lng:pickup")
        XCTAssertEqual(axis("Pickup Longitude"), "lng:pickup")
        XCTAssertEqual(axis("lat2"), "lat:2")
        XCTAssertEqual(axis("long_description"), "lng:description")
        XCTAssertNil(axis("latlng"))
        XCTAssertNil(axis("lat_lng"))
        XCTAssertNil(axis("relation"))
        XCTAssertNil(axis("platform"))
        XCTAssertNil(axis("longest"))
    }

    func testCombinedColumnNames() {
        for name in ["koordinat", "coordinates", "lat_lng", "LatLng", "latlong", "lokasi", "gps", "location"] {
            XCTAssertTrue(CoordinateNames.isCombined(name), name)
        }
        for name in ["latitude", "address", "alamat", "note"] {
            XCTAssertFalse(CoordinateNames.isCombined(name), name)
        }
    }

    func testLabelColumnPrefersExactNamesThenNameWords() {
        XCTAssertEqual(MapSourceDetector.labelColumn(columnNames: ["id", "nama_pelanggan", "Name"]), 2)
        XCTAssertEqual(MapSourceDetector.labelColumn(columnNames: ["id", "nama_pelanggan", "alamat"]), 1)
        XCTAssertEqual(MapSourceDetector.labelColumn(columnNames: ["id", "customerName"]), 1)
        XCTAssertNil(MapSourceDetector.labelColumn(columnNames: ["id", "alamat"]))
    }

    // MARK: - Detection

    private func column(_ id: Int, _ name: String, _ kind: DBValueKind, _ type: String = "varchar") -> ColumnMeta {
        ColumnMeta(id: id, name: name, nativeTypeName: type, kind: kind)
    }

    private func detect(_ columns: [ColumnMeta], _ rows: [[DBValue]]) -> [MapSource] {
        MapSourceDetector.detect(columns: columns, rowCount: rows.count, dialect: .mysql) { row, column in
            rows[row][column]
        }
    }

    /// The table from the report: latitude and longitude as varchar, next to a NULL column.
    func testVarcharLatitudeLongitudePairIsFound() {
        let columns = [
            column(0, "id", .int, "int"), column(1, "denah", .string), column(2, "latitude", .string),
            column(3, "longitude", .string),
        ]
        let rows: [[DBValue]] = [
            [.int(1), .null, .string("-8.59940239"), .string("116.0977978")],
            [.int(2), .null, .string("-8.595696215758"), .string("116.10714587645")],
            [.int(3), .null, .string("-8.59593846"), .string("116.1079168")],
        ]
        XCTAssertEqual(detect(columns, rows), [.pair(latitude: 2, longitude: 3, swapped: false)])
        XCTAssertEqual(
            MapSource.pair(latitude: 2, longitude: 3, swapped: false).title(columnNames: columns.map(\.name)),
            "latitude, longitude")
    }

    func testNumericPairsSeveralPairsAndPrefixes() {
        let columns = [
            column(0, "pickup_lat", .decimal, "decimal(10,7)"), column(1, "pickup_lng", .decimal, "decimal(10,7)"),
            column(2, "dropLat", .double, "double"), column(3, "dropLon", .double, "double"),
            column(4, "long_description", .string),
        ]
        let rows: [[DBValue]] = [
            [.decimal("-8.5994024"), .decimal("116.0977978"), .double(-8.6), .double(116.2), .string("far away")]
        ]
        XCTAssertEqual(
            detect(columns, rows),
            [.pair(latitude: 0, longitude: 1, swapped: false), .pair(latitude: 2, longitude: 3, swapped: false)])
    }

    func testSwappedPairIsReadTheRightWayAndSaysSo() {
        let columns = [column(0, "lat", .string), column(1, "lng", .string)]
        let rows: [[DBValue]] = [
            [.string("116.0977978"), .string("-8.59940239")], [.string("116.1"), .string("-8.6")],
        ]
        XCTAssertEqual(detect(columns, rows), [.pair(latitude: 1, longitude: 0, swapped: true)])
    }

    func testNamesAloneAreNotEnoughWhenTheValuesAreNotCoordinates() {
        let columns = [column(0, "lat", .string), column(1, "long", .string)]
        let words: [[DBValue]] = [[.string("yes"), .string("no")], [.string("a"), .string("b")]]
        XCTAssertEqual(detect(columns, words), [])
        // Integers far beyond degrees (a microdegree encoding) are not placed either.
        let microdegrees: [[DBValue]] = [[.int(-8_599_402), .int(116_097_797)]]
        XCTAssertEqual(
            detect([column(0, "lat", .int, "int"), column(1, "lng", .int, "int")], microdegrees), [])
        // A half without its partner is not a source.
        XCTAssertEqual(detect([column(0, "latitude", .string)], [[.string("-8.6")]]), [])
    }

    func testOneBadRowDoesNotHideAPairAndAnEmptyTableIsTakenOnItsNames() {
        let columns = [column(0, "latitude", .string), column(1, "longitude", .string)]
        let rows: [[DBValue]] = [
            [.string("n/a"), .string("n/a")], [.string("-8.59"), .string("116.09")],
            [.null, .null], [.string("0"), .string("0")], [.string("-8,60"), .string("116,10")],
        ]
        XCTAssertEqual(detect(columns, rows), [.pair(latitude: 0, longitude: 1, swapped: false)])
        XCTAssertEqual(detect(columns, []), [.pair(latitude: 0, longitude: 1, swapped: false)])
    }

    func testCombinedColumnAndItsOrder() {
        let columns = [column(0, "koordinat", .string), column(1, "lokasi", .string), column(2, "gps", .string)]
        let rows: [[DBValue]] = [
            [.string("-8.5994, 116.0977"), .string("Mataram"), .string("116.0977,-8.5994")],
            [.string("-8.60; 116.10"), .string("Ampenan"), .string("116.10,-8.60")],
        ]
        XCTAssertEqual(
            detect(columns, rows), [.combined(0, longitudeFirst: false), .combined(2, longitudeFirst: true)])
    }

    func testGeometryComesFirstAndIsNotReadAsAPair() {
        let columns = [
            column(0, "location", .raw, "geometry"), column(1, "lat", .double, "double"),
            column(2, "lng", .double, "double"),
        ]
        let rows: [[DBValue]] = [[.string("POINT(116.1 -8.6)"), .double(-8.6), .double(116.1)]]
        XCTAssertEqual(
            detect(columns, rows), [.geometry(0), .pair(latitude: 1, longitude: 2, swapped: false)])
        XCTAssertEqual(
            MapSourceDetector.source(for: 2, among: detect(columns, rows)),
            .pair(latitude: 1, longitude: 2, swapped: false))
        XCTAssertEqual(MapSourceDetector.source(for: 5, among: detect(columns, rows)), .geometry(0))
    }

    // MARK: - Reading

    func testReadingRowsCountsEmptyUnreadableAndOutOfRange() throws {
        let source = MapSource.pair(latitude: 0, longitude: 1, swapped: false)
        func read(_ latitude: DBValue, _ longitude: DBValue) -> MapReading {
            MapSourceDetector.read(source, dialect: .postgresql) { $0 == 0 ? latitude : longitude }
        }
        guard case let .feature(feature) = read(.string(" -8,5994 "), .string("116.0977")),
            case let .point(point) = feature.shape
        else { return XCTFail("a varchar pair is a point") }
        XCTAssertEqual(point.latitude, -8.5994, accuracy: 1e-12)
        XCTAssertEqual(point.longitude, 116.0977, accuracy: 1e-12)
        XCTAssertEqual(feature.srid, 4326)
        XCTAssertFalse(feature.isUnplaceable)

        XCTAssertEqual(read(.null, .null), .empty)
        XCTAssertEqual(read(.string(""), .string(" ")), .empty)
        XCTAssertEqual(read(.string("0"), .decimal("0.000")), .empty, "0, 0 means not filled in")
        XCTAssertEqual(read(.string("-8.6"), .null), .unreadable, "half a location")
        XCTAssertEqual(read(.string("abc"), .string("116")), .unreadable)
        // Row by row there is no guessing: a latitude of 116 is simply off the earth.
        XCTAssertEqual(read(.string("116.1"), .string("-8.6")), .outOfRange)
        XCTAssertEqual(read(.string("95"), .string("116")), .outOfRange)
        XCTAssertEqual(read(.string("-8.6"), .string("190")), .outOfRange)
    }

    func testCoordinateTextKeepsTheServerDigits() {
        let pair = MapSource.pair(latitude: 0, longitude: 1, swapped: false)
        let values: [DBValue] = [.decimal("-8.5956962157580"), .string(" 116.10714587645 ")]
        XCTAssertEqual(
            MapSourceDetector.coordinateText(pair, dialect: .mysql) { values[$0] },
            "-8.5956962157580, 116.10714587645")
        let combined = MapSource.combined(0, longitudeFirst: true)
        XCTAssertEqual(
            MapSourceDetector.coordinateText(combined, dialect: .mysql) { _ in .string("116.1,-8.6") }, "-8.6, 116.1")
        let geometry = MapSource.geometry(0)
        XCTAssertEqual(
            MapSourceDetector.coordinateText(geometry, dialect: .postgresql) { _ in .string("POINT(116.1 -8.6)") },
            "-8.6, 116.1")
        XCTAssertNil(
            MapSourceDetector.coordinateText(geometry, dialect: .postgresql) { _ in
                .string("LINESTRING(116.1 -8.6, 116.2 -8.7)")
            })
    }

    func testAnchorIsThePointOrTheMiddleOfTheShape() throws {
        XCTAssertEqual(GeoShape.point(GeoPoint(longitude: 1, latitude: 2)).anchor, GeoPoint(longitude: 1, latitude: 2))
        let line = GeoShape.line([GeoPoint(longitude: 0, latitude: 0), GeoPoint(longitude: 2, latitude: 4)])
        XCTAssertEqual(line.anchor, GeoPoint(longitude: 1, latitude: 2))
    }
}
