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

    /// Text in any script goes from a table to Excel and back into a table unchanged, on
    /// every engine, with the table's columns choosing their file column — one file
    /// column filling two of them.
    func testTextInAnyScriptSurvivesExcelOnEveryEngine() async throws {
        let servers = try await everyServer()
        var reached: [String] = []
        let texts = [
            "Café Münster", "日本語のテキスト", "Ωμέγα", "emoji 🎉 selesai", "Rp 1.500,00", "\"dikutip\" & <tag> 'apos'",
            "baris satu\nbaris dua", "=SUM(A1:A9)", "+62 812 3456", "-minus", "@handle", "_x0041_ bukan A",
            "ñandú — “kutip” …",
        ]
        try await withSession(on: servers) { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let engine = server.engine == .sqlite ? "sqlite" : "\(server.engine.rawValue):\(server.port)"
            reached.append(engine)
            let charset = dialect == .mysql ? " CHARACTER SET utf8mb4" : ""
            for name in ["xlsx_text_source", "xlsx_text_import"] {
                _ = try await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
            }
            do {
                _ = try await connection.executeCollecting(
                    "CREATE TABLE xlsx_text_source (id INTEGER PRIMARY KEY, teks VARCHAR(200) NOT NULL)\(charset)")
                _ = try await connection.executeCollecting(
                    """
                    CREATE TABLE xlsx_text_import (
                        id INTEGER PRIMARY KEY, teks VARCHAR(200) NOT NULL, salinan VARCHAR(200),
                        catatan VARCHAR(20))\(charset)
                    """)
                for (index, text) in texts.enumerated() {
                    _ = try await connection.executeCollecting(
                        "INSERT INTO xlsx_text_source (id, teks) VALUES "
                            + "(\(SQLLiteralPlaceholder.pair(dialect)))",
                        parameters: [.int(Int64(index + 1)), .string(text)])
                }

                // Export, the way the Export sheet does it.
                let source = try await connection.executeCollecting(
                    "SELECT id, teks FROM xlsx_text_source ORDER BY id")
                XCTAssertEqual(source.rows.map { $0[1].text }, texts, "\(engine): the server holds the text")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
                defer { try? FileManager.default.removeItem(at: url) }
                var options = ExportOptions()
                options.format = .xlsx
                let exporter = try RowExporter(url: url, options: options)
                try exporter.begin(columns: source.columns)
                exporter.write(rows: source.rows)
                try exporter.finish()

                // Import, the way the Import sheet does it.
                let table = TableRef(schema: server.fixtureSchema, name: "xlsx_text_import")
                let columns = try await connection.introspector.columns(of: table)
                let data = try Data(contentsOf: url)
                XCTAssertEqual(try ImportFileProbe.format(url: url, data: data), .xlsx, engine)
                let workbook = try XLSXWorkbook(data: data)
                var probe = workbook.rows()
                let header = try XCTUnwrap(probe.next(), engine)
                var assignments = CSVImportPlan.assignmentsByName(header: header, columns: columns)
                XCTAssertEqual(assignments.map(\.column), ["id", "teks"], engine)
                assignments.append(ImportAssignment(column: "salinan", source: 1))
                XCTAssertTrue(CSVImportPlan.missingRequired(assignments, columns: columns).isEmpty, engine)
                let plan = CSVImportPlan(table: table, assignments: assignments, sourceCount: header.count)
                var reader = workbook.rows()
                let inserted = try await CSVImporter(plan: plan, columns: columns, dialect: dialect)
                    .run(reader: &reader, on: connection)
                XCTAssertEqual(inserted, Int64(texts.count), engine)

                let imported = try await connection.executeCollecting(
                    "SELECT teks, salinan, catatan FROM xlsx_text_import ORDER BY id")
                XCTAssertEqual(imported.rows.map { $0[0].text }, texts, engine)
                XCTAssertEqual(imported.rows.map { $0[1].text }, texts, engine)
                XCTAssertTrue(imported.rows.allSatisfy { $0[2] == .null }, engine)
            } catch {
                for name in ["xlsx_text_source", "xlsx_text_import"] {
                    _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
                }
                throw error
            }
            for name in ["xlsx_text_source", "xlsx_text_import"] {
                _ = try await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
            }
        }
        XCTAssertEqual(reached.count, servers.count)
        TestLog.note("xlsx text round trip checked on \(reached.joined(separator: ", "))")
    }
}

/// `$1, $2` or `?, ?`, for the one statement above that binds by hand.
private enum SQLLiteralPlaceholder {
    static func pair(_ dialect: SQLDialect) -> String {
        dialect == .postgresql ? "$1, $2" : "?, ?"
    }
}
