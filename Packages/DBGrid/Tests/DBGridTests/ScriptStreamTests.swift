import DBCore
import Foundation
import XCTest

@testable import DBGrid

/// The streaming pieces an import is made of: gzip in and out, the chunked file reader
/// and the incremental splitter, which must give the same answer however the bytes
/// are cut up.
final class ScriptStreamTests: XCTestCase {
    private func split(_ script: String, dialect: SQLDialect, pieceSize: Int) -> [ScriptChunk] {
        var splitter = IncrementalStatementSplitter(dialect: dialect)
        var chunks: [ScriptChunk] = []
        let bytes = Array(script.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + pieceSize, bytes.count)
            chunks += splitter.feed(Data(bytes[index ..< end]))
            index = end
        }
        chunks += splitter.finish()
        return chunks
    }

    /// Every piece size from one byte up must yield the same chunks.
    private func assertStable(
        _ script: String, dialect: SQLDialect, expected: [ScriptChunk], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for size in [1, 2, 3, 7, 16, 64, 4_096] {
            XCTAssertEqual(
                split(script, dialect: dialect, pieceSize: size), expected, "piece size \(size)", file: file, line: line
            )
        }
    }

    func testStatementsSplitOnSemicolonsWhateverThePieceSize() {
        let script = "CREATE TABLE t (a int);\nINSERT INTO t VALUES (1), (2);\n\nSELECT 'a;b' AS x"
        assertStable(
            script, dialect: .postgresql,
            expected: [
                .statement("CREATE TABLE t (a int)", line: 1),
                .statement("INSERT INTO t VALUES (1), (2)", line: 2),
                .statement("SELECT 'a;b' AS x", line: 4),
            ])
    }

    func testCommentsBetweenStatementsAreDroppedAndInsideKept() {
        let script = """
            -- header; not a statement
            /* block; comment */
            CREATE TABLE t (a int -- trailing; comment
            );
            /* only a comment */;
            """
        assertStable(
            script, dialect: .postgresql,
            expected: [.statement("CREATE TABLE t (a int -- trailing; comment\n)", line: 3)])
    }

    func testDollarQuotedBodiesAndNestedCommentsHoldSemicolons() {
        let script = """
            CREATE FUNCTION f() RETURNS int AS $body$
            BEGIN; RETURN 1; END;
            $body$ LANGUAGE plpgsql;
            /* outer /* inner; */ still; */ SELECT $1;
            """
        assertStable(
            script, dialect: .postgresql,
            expected: [
                .statement(
                    "CREATE FUNCTION f() RETURNS int AS $body$\nBEGIN; RETURN 1; END;\n$body$ LANGUAGE plpgsql", line: 1
                ),
                .statement("SELECT $1", line: 4),
            ])
    }

    func testMySQLDelimiterConditionalCommentsAndEscapes() {
        let script = """
            /*!40101 SET NAMES utf8mb4 */;
            # hash comment;
            INSERT INTO t VALUES ('it\\'s; fine', "a;b");
            DELIMITER ;;
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END;;
            DELIMITER ;
            SELECT `x;y` FROM t;
            """
        assertStable(
            script, dialect: .mysql,
            expected: [
                .statement("/*!40101 SET NAMES utf8mb4 */", line: 1),
                .statement("INSERT INTO t VALUES ('it\\'s; fine', \"a;b\")", line: 3),
                .statement("CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", line: 5),
                .statement("SELECT `x;y` FROM t", line: 7),
            ])
    }

    func testCopyBlocksPassTheirRowsThroughUntouched() {
        let script = """
            \\restrict abc
            SET client_encoding = 'UTF8';
            COPY public."Places" (id, name) FROM stdin;
            1\tMonas
            2\tKota\\tTua
            \\.

            COPY other FROM stdin;
            \\.
            SELECT 1;
            """
        assertStable(
            script, dialect: .postgresql,
            expected: [
                .statement("SET client_encoding = 'UTF8'", line: 2),
                .copyBegin(
                    table: TableRef(database: "", schema: "public", name: "Places"), columns: ["id", "name"],
                    sql: "COPY public.\"Places\" (id, name) FROM stdin"),
                .copyLines(Data("1\tMonas\n2\tKota\\tTua\n".utf8)),
                .copyEnd,
                .copyBegin(
                    table: TableRef(database: "", schema: "public", name: "other"), columns: [],
                    sql: "COPY other FROM stdin"),
                .copyEnd,
                .statement("SELECT 1", line: 10),
            ])
    }

    func testUnterminatedLastStatementIsFlushedAtTheEnd() {
        assertStable("SELECT 1", dialect: .mysql, expected: [.statement("SELECT 1", line: 1)])
        assertStable("SELECT 1;\n  \n", dialect: .mysql, expected: [.statement("SELECT 1", line: 1)])
    }

    func testCopyTargetParsing() {
        let parsed = IncrementalStatementSplitter.copyFromStdin("COPY \"my schema\".\"T\" (\"A\", b) FROM stdin")
        XCTAssertEqual(parsed?.table, TableRef(database: "", schema: "my schema", name: "T"))
        XCTAssertEqual(parsed?.columns, ["A", "b"])
        XCTAssertNil(IncrementalStatementSplitter.copyFromStdin("COPY t TO stdout"))
        XCTAssertNil(IncrementalStatementSplitter.copyFromStdin("COPY t FROM '/tmp/x'"))
    }

    func testGzipRoundTripsAcrossPieces() throws {
        let text = String(repeating: "INSERT INTO t VALUES ('ünïcödé', 42);\n", count: 5_000)
        let deflater = try GzipDeflater()
        var compressed = Data()
        let bytes = Data(text.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + 7_001, bytes.count)
            compressed += try deflater.compress(bytes[index ..< end])
            index = end
        }
        compressed += try deflater.compress(Data(), finish: true)
        XCTAssertLessThan(compressed.count, bytes.count / 10)
        XCTAssertEqual(compressed[0], 0x1F)
        XCTAssertEqual(compressed[1], 0x8B)

        let inflater = try GzipInflater()
        var restored = Data()
        index = 0
        while index < compressed.count {
            let end = min(index + 333, compressed.count)
            restored += try inflater.decompress(compressed[index ..< end])
            index = end
        }
        XCTAssertTrue(inflater.isFinished)
        XCTAssertEqual(restored, bytes)
    }

    func testByteSourceReadsPlainAndGzipFilesTheSame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "script-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = "\u{FEFF}" + String(repeating: "SELECT 'x';\n", count: 200_000)

        let plain = directory.appendingPathComponent("plain.sql")
        try Data(script.utf8).write(to: plain)
        let gz = directory.appendingPathComponent("packed.sql.gz")
        let writer = try ScriptFileWriter(url: gz, dialect: .postgresql, compress: true)
        try writer.writeRaw(script)
        try writer.finish()

        for url in [plain, gz] {
            let source = try ScriptByteSource(url: url)
            var collected = Data()
            var reads = 0
            while let piece = try source.next() {
                collected += piece
                reads += 1
            }
            XCTAssertEqual(source.isCompressed, url == gz)
            XCTAssertEqual(source.bytesRead, source.totalBytes)
            if url == plain { XCTAssertGreaterThan(reads, 1, "a file bigger than one chunk arrives in pieces") }
            XCTAssertEqual(
                String(decoding: collected, as: UTF8.self), String(script.dropFirst()), "the byte-order mark is dropped"
            )
        }
    }

    func testFileWriterFencesMySQLRoutinesAndLaysOutCopyBlocks() throws {
        let directory = FileManager.default.temporaryDirectory
        let mysql = directory.appendingPathComponent("writer-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: mysql) }
        let writer = try ScriptFileWriter(url: mysql, dialect: .mysql, compress: false)
        try writer.write(.statement("CREATE TABLE t (a int)", line: 0))
        try writer.write(.statement("CREATE PROCEDURE p() BEGIN SELECT 1; END", line: 0))
        try writer.finish()
        let text = try String(contentsOf: mysql, encoding: .utf8)
        XCTAssertEqual(
            text, "CREATE TABLE t (a int);\nDELIMITER ;;\nCREATE PROCEDURE p() BEGIN SELECT 1; END;;\nDELIMITER ;\n")
        // What was written splits back into the same statements.
        let chunks = split(text, dialect: .mysql, pieceSize: 5)
        XCTAssertEqual(
            chunks.map { if case let .statement(sql, _) = $0 { sql } else { "" } },
            ["CREATE TABLE t (a int)", "CREATE PROCEDURE p() BEGIN SELECT 1; END"])

        let pg = directory.appendingPathComponent("writer-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: pg) }
        let pgWriter = try ScriptFileWriter(url: pg, dialect: .postgresql, compress: false)
        let table = TableRef(database: "", schema: "public", name: "t")
        try pgWriter.write(.copyBegin(table: table, columns: ["a"], sql: "COPY public.t (a) FROM stdin"))
        try pgWriter.write(.copyLines(Data("1\n2\n".utf8)))
        try pgWriter.write(.copyEnd)
        try pgWriter.finish()
        let pgText = try String(contentsOf: pg, encoding: .utf8)
        XCTAssertEqual(pgText, "COPY public.t (a) FROM stdin;\n1\n2\n\\.\n\n")
        XCTAssertEqual(
            split(pgText, dialect: .postgresql, pieceSize: 3),
            [
                .copyBegin(table: table, columns: ["a"], sql: "COPY public.t (a) FROM stdin"),
                .copyLines(Data("1\n2\n".utf8)), .copyEnd,
            ])
    }

    func testChannelAppliesBackPressureAndCloses() async throws {
        let channel = ScriptChannel(capacity: 2)
        let producer = Task {
            var sent = 0
            do {
                for index in 0 ..< 10 {
                    try await channel.send(.statement("S\(index)", line: index))
                    sent += 1
                }
                await channel.finish()
            } catch {}
            return sent
        }
        var received: [String] = []
        while let chunk = try await channel.next(), received.count < 4 {
            if case let .statement(sql, _) = chunk { received.append(sql) }
        }
        XCTAssertEqual(received, ["S0", "S1", "S2", "S3"])
        await channel.close()
        let sent = await producer.value
        XCTAssertLessThan(sent, 10, "closing the channel stops the producer")
    }
}
