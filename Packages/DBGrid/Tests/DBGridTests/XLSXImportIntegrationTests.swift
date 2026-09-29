import DBCore
import DBTestKit
import Foundation
import XCTest

@testable import DBGrid

/// The report end to end: rows exported to Excel and imported from that file land in a
/// table as they left, on every engine. Before the workbook reader, the file was read as
/// CSV and its header was the zip's binary.
extension ScriptTransferIntegrationTests {
    func testRowsExportedToExcelImportBackOnEveryEngine() async throws {
        let servers = try await everyServer()
        var reached: [String] = []
        try await withSession(on: servers) { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let engine = server.engine == .sqlite ? "sqlite" : "\(server.engine.rawValue):\(server.port)"
            reached.append(engine)
            let select =
                "SELECT id, nama, latitude, longitude, koordinat, pickup_lat, pickup_lng FROM %@ ORDER BY id"

            // Export, the way the Export sheet does it.
            let source = try await connection.executeCollecting(
                select.replacingOccurrences(of: "%@", with: "latlng_places"))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
            defer { try? FileManager.default.removeItem(at: url) }
            var options = ExportOptions()
            options.format = .xlsx
            let exporter = try RowExporter(url: url, options: options)
            try exporter.begin(columns: source.columns)
            exporter.write(rows: source.rows)
            try exporter.finish()

            // Import into an empty table of the same shape, the way the Import sheet does it.
            let decimal = dialect == .sqlite ? "REAL" : "DECIMAL(10,7)"
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS xlsx_import")
            _ = try await connection.executeCollecting(
                """
                CREATE TABLE xlsx_import (
                    id INTEGER PRIMARY KEY, nama VARCHAR(80) NOT NULL, latitude VARCHAR(32),
                    longitude VARCHAR(32), koordinat VARCHAR(64), pickup_lat \(decimal), pickup_lng \(decimal))
                """)
            do {
                let table = TableRef(schema: server.fixtureSchema, name: "xlsx_import")
                let columns = try await connection.introspector.columns(of: table)
                let data = try Data(contentsOf: url)
                XCTAssertEqual(TabularFormat.detect(url: url, data: data), .xlsx, engine)
                let workbook = try XLSXWorkbook(data: data)
                var probe = workbook.rows()
                let header = try XCTUnwrap(probe.next(), engine)
                XCTAssertEqual(
                    header, ["id", "nama", "latitude", "longitude", "koordinat", "pickup_lat", "pickup_lng"], engine)
                let plan = CSVImportPlan.matched(header: header, to: columns, table: table)
                XCTAssertEqual(plan.mapping.compactMap { $0 }.count, 7, "\(engine): every column maps by name")
                let importer = CSVImporter(plan: plan, columns: columns, dialect: dialect)
                var reader = workbook.rows()
                let inserted = try await importer.run(reader: &reader, on: connection)
                XCTAssertEqual(inserted, Int64(source.rows.count), engine)

                let imported = try await connection.executeCollecting(
                    select.replacingOccurrences(of: "%@", with: "xlsx_import"))
                XCTAssertEqual(imported.rows.count, source.rows.count, engine)
                for (before, after) in zip(source.rows, imported.rows) {
                    // Text, not values: the decimals must come back with the same digits.
                    XCTAssertEqual(after.map(\.text), before.map(\.text), engine)
                }
            } catch {
                _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS xlsx_import")
                throw error
            }
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS xlsx_import")
        }
        XCTAssertEqual(reached.count, servers.count)
        TestLog.note("xlsx round trip checked on \(reached.joined(separator: ", "))")
    }
}
