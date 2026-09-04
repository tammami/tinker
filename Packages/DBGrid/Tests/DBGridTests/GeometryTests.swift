import DBCore
import Foundation
import XCTest

@testable import DBGrid

final class GeometryTests: XCTestCase {
    // PostGIS: SELECT ST_AsEWKB('SRID=4326;POINT(106.8 -6.2)') → hex EWKB, little-endian, SRID flag set.
    let pointHex = "0101000020E6100000" + "3333333333B35A40" + "CDCCCCCCCCCC18C0"

    func testEWKBPointWithSRID() throws {
        let feature = try XCTUnwrap(GeometryParser.parse(text: pointHex, dialect: .postgresql))
        XCTAssertEqual(feature.srid, 4326)
        XCTAssertFalse(feature.isUnplaceable)
        guard case let .point(point) = feature.shape else { return XCTFail("not a point") }
        XCTAssertEqual(point.longitude, 106.8, accuracy: 1e-9)
        XCTAssertEqual(point.latitude, -6.2, accuracy: 1e-9)
        XCTAssertEqual(feature.shape.wkt, "POINT(106.8 -6.2)")
        // The same bytes as the driver hands them over.
        let fromBytes = GeometryParser.parse(
            .raw(typeName: "geometry", text: nil, bytes: Data(hex: pointHex)), dialect: .postgresql)
        XCTAssertEqual(fromBytes?.shape, feature.shape)
    }

    func testEWKBLineAndPolygonWithZ() throws {
        // LINESTRING Z (0 0 1, 1 1 2) with the Z flag, no SRID.
        var line = Data([0x01]) + UInt32(0x8000_0002).littleEndianBytes + UInt32(2).littleEndianBytes
        for value in [0.0, 0.0, 1.0, 1.0, 1.0, 2.0] { line += value.littleEndianBytes }
        let feature = try XCTUnwrap(GeometryParser.parse(bytes: line, dialect: .postgresql))
        XCTAssertEqual(
            feature.shape, .line([GeoPoint(longitude: 0, latitude: 0), GeoPoint(longitude: 1, latitude: 1)]))
        XCTAssertNil(feature.srid)

        // POLYGON((0 0, 2 0, 2 2, 0 0)) big-endian.
        var polygon = Data([0x00]) + UInt32(3).bigEndianBytes + UInt32(1).bigEndianBytes + UInt32(4).bigEndianBytes
        for value in [0.0, 0.0, 2.0, 0.0, 2.0, 2.0, 0.0, 0.0] { polygon += value.bigEndianBytes }
        let shape = try XCTUnwrap(GeometryParser.parse(bytes: polygon, dialect: .postgresql)).shape
        guard case let .polygon(rings) = shape else { return XCTFail("not a polygon") }
        XCTAssertEqual(rings.count, 1)
        XCTAssertEqual(rings[0].count, 4)
        XCTAssertEqual(shape.summary, "POLYGON · 4 vertices")
        XCTAssertEqual(shape.bounds?.maxLongitude, 2)
    }

    func testMySQLPrefixesSRIDAndStoresLongitudeFirst() throws {
        // MySQL: SRID 4326 little-endian, then WKB with x = longitude, y = latitude.
        var bytes = UInt32(4326).littleEndianBytes + Data([0x01]) + UInt32(1).littleEndianBytes
        bytes += 106.8.littleEndianBytes + (-6.2).littleEndianBytes
        let feature = try XCTUnwrap(
            GeometryParser.parse(.raw(typeName: "geometry", text: nil, bytes: bytes), dialect: .mysql))
        XCTAssertEqual(feature.srid, 4326)
        guard case let .point(point) = feature.shape else { return XCTFail("not a point") }
        XCTAssertEqual(point.longitude, 106.8, accuracy: 1e-9)
        XCTAssertEqual(point.latitude, -6.2, accuracy: 1e-9)
    }

    func testWebMercatorIsUnprojectedAndUnknownSRIDsAreJudgedByRange() throws {
        // SRID=3857;POINT(11888900 -694000) ≈ lon 106.8, lat -6.23.
        let mercator = try XCTUnwrap(
            GeometryParser.parse(text: "SRID=3857;POINT(11888900 -694000)", dialect: .postgresql))
        guard case let .point(point) = mercator.shape else { return XCTFail("not a point") }
        XCTAssertEqual(point.longitude, 106.8, accuracy: 0.05)
        XCTAssertEqual(point.latitude, -6.23, accuracy: 0.05)
        XCTAssertFalse(mercator.isUnplaceable)

        let utm = try XCTUnwrap(GeometryParser.parse(text: "SRID=32748;POINT(700000 9310000)", dialect: .postgresql))
        XCTAssertTrue(utm.isUnplaceable, "metres in an unknown projection cannot be placed")
        let degrees = try XCTUnwrap(GeometryParser.parse(text: "POINT(10 20)", dialect: .postgresql))
        XCTAssertFalse(degrees.isUnplaceable, "small numbers without an SRID are taken as degrees")
    }

    func testWKTShapes() throws {
        let multi = try XCTUnwrap(
            GeometryParser.parse(
                text: "MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((2 2,3 2,3 3,2 2),(2.2 2.2,2.5 2.2,2.5 2.5,2.2 2.2)))",
                dialect: .postgresql))
        guard case let .multiPolygon(polygons) = multi.shape else { return XCTFail("not a multipolygon") }
        XCTAssertEqual(polygons.count, 2)
        XCTAssertEqual(polygons[1].count, 2, "the second polygon has a hole")
        let collection = try XCTUnwrap(
            GeometryParser.parse(text: "GEOMETRYCOLLECTION(POINT(1 2), LINESTRING(0 0, 1 1))", dialect: .postgresql))
        XCTAssertEqual(collection.shape.vertexCount, 3)
        XCTAssertEqual(collection.shape.typeName, "GEOMETRYCOLLECTION")
        XCTAssertNotNil(GeometryParser.parse(text: "MULTIPOINT((1 2), (3 4))", dialect: .postgresql))
        XCTAssertNotNil(GeometryParser.parse(text: "POINT Z (1 2 3)", dialect: .postgresql))
        XCTAssertNil(GeometryParser.parse(text: "hello world", dialect: .postgresql))
        XCTAssertNil(GeometryParser.parse(text: "POINT(1)", dialect: .postgresql))
    }

    func testGeometryTypeNames() {
        XCTAssertTrue(GeometryParser.isGeometryType("geometry(Point,4326)"))
        XCTAssertTrue(GeometryParser.isGeometryType("geography"))
        XCTAssertTrue(GeometryParser.isGeometryType("point"))
        XCTAssertFalse(GeometryParser.isGeometryType("text"))
    }
}

extension UInt32 {
    var littleEndianBytes: Data { withUnsafeBytes(of: self.littleEndian) { Data($0) } }
    var bigEndianBytes: Data { withUnsafeBytes(of: self.bigEndian) { Data($0) } }
}

extension Double {
    var littleEndianBytes: Data { withUnsafeBytes(of: bitPattern.littleEndian) { Data($0) } }
    var bigEndianBytes: Data { withUnsafeBytes(of: bitPattern.bigEndian) { Data($0) } }
}
