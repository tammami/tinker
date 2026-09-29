import DBCore
import DBTestKit
import XCTest

@testable import DBGrid

/// Locations as application tables keep them, read through each real driver: varchar
/// latitude/longitude, one text column with both, and a decimal pair
/// (`testenv/fixtures/*/005_latlng.sql`).
extension ScriptTransferIntegrationTests {
    func testLatitudeLongitudeColumnsAreFoundAndPlacedOnEveryEngine() async throws {
        let servers = try await everyServer()
        var engines: [String] = []
        try await withSession(on: servers) { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let result = try await connection.executeCollecting(
                "SELECT id, nama, latitude, longitude, koordinat, pickup_lat, pickup_lng FROM latlng_places ORDER BY id"
            )
            let engine = server.engine == .sqlite ? "sqlite" : "\(server.engine.rawValue):\(server.port)"
            engines.append(engine)
            XCTAssertEqual(result.rows.count, 8, engine)

            let sources = MapSourceDetector.detect(
                columns: result.columns, rowCount: result.rows.count, dialect: dialect
            ) { row, column in result.rows[row][column] }
            XCTAssertEqual(
                sources,
                [
                    .pair(latitude: 2, longitude: 3, swapped: false),
                    .pair(latitude: 5, longitude: 6, swapped: false),
                    .combined(4, longitudeFirst: false),
                ],
                "\(engine): \(result.columns.map { "\($0.name) \($0.nativeTypeName) \($0.kind)" })")
            XCTAssertEqual(MapSourceDetector.labelColumn(columnNames: result.columns.map(\.name)), 1, engine)

            for source in sources {
                var placed: [Int] = []
                var empty: [Int] = []
                var unreadable: [Int] = []
                var outOfRange: [Int] = []
                for (index, row) in result.rows.enumerated() {
                    switch MapSourceDetector.read(source, dialect: dialect, value: { row[$0] }) {
                    case let .feature(feature):
                        XCTAssertFalse(feature.isUnplaceable, "\(engine) \(source) row \(index + 1)")
                        guard case let .point(point) = feature.shape else {
                            XCTFail("\(engine) \(source) row \(index + 1) is not a point")
                            continue
                        }
                        // Every placed row is on Lombok.
                        XCTAssertEqual(point.latitude, -8.55, accuracy: 0.1, "\(engine) \(source) row \(index + 1)")
                        XCTAssertEqual(point.longitude, 116.09, accuracy: 0.1, "\(engine) \(source) row \(index + 1)")
                        placed.append(index + 1)
                    case .empty: empty.append(index + 1)
                    case .unreadable: unreadable.append(index + 1)
                    case .outOfRange: outOfRange.append(index + 1)
                    }
                }
                XCTAssertEqual(placed, [1, 2, 3, 4], "\(engine) \(source)")
                if case .pair(5, 6, _) = source {
                    XCTAssertEqual(empty, [5, 6, 7, 8], "\(engine): the decimal pair is NULL from row 5")
                } else {
                    XCTAssertEqual(empty, [5, 6], "\(engine) \(source)")
                    XCTAssertEqual(unreadable, [7], "\(engine) \(source)")
                    XCTAssertEqual(outOfRange, [8], "\(engine) \(source)")
                }
            }

            // The pin and Copy Coordinates keep the server's own digits.
            let first = result.rows[0]
            XCTAssertEqual(
                MapSourceDetector.coordinateText(sources[0], dialect: dialect) { first[$0] },
                "-8.59940239, 116.0977978", engine)
            XCTAssertEqual(
                MapSourceDetector.coordinateText(sources[2], dialect: dialect) { first[$0] },
                "-8.59940239, 116.0977978", engine)
        }
        // Every configured server was reached, not skipped.
        XCTAssertEqual(engines.count, servers.count)
        TestLog.note("latlng_places checked on \(engines.joined(separator: ", "))")
    }
}
