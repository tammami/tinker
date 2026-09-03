import DBCore
import DBSQL
import XCTest
@testable import DBGrid

final class RowBufferTests: XCTestCase {
    func makeRows(_ range: Range<Int>) -> [[DBValue]] {
        range.map { [.int(Int64($0)), .string("row \($0)")] }
    }

    func testStoresAndReadsByAbsoluteIndex() {
        var buffer = RowBuffer(pageSize: 10)
        buffer.store(page: 0, rows: makeRows(0 ..< 10))
        buffer.store(page: 3, rows: makeRows(30 ..< 40))

        XCTAssertEqual(buffer.row(at: 0)?.first, .int(0))
        XCTAssertEqual(buffer.row(at: 9)?.first, .int(9))
        XCTAssertEqual(buffer.row(at: 35)?.first, .int(35))
        XCTAssertNil(buffer.row(at: 15), "page 1 was never loaded")
        XCTAssertNil(buffer.row(at: -1))
        XCTAssertEqual(buffer.count, 20)
    }

    func testMissingPagesForARange() {
        var buffer = RowBuffer(pageSize: 10)
        buffer.store(page: 1, rows: makeRows(10 ..< 20))
        XCTAssertEqual(buffer.missingPages(for: 5 ..< 35), [0, 2, 3])
        XCTAssertEqual(buffer.missingPages(for: 10 ..< 20), [])
        XCTAssertEqual(buffer.missingPages(for: 0 ..< 0), [])
        XCTAssertTrue(buffer.isLoaded(range: 10 ..< 20))
        XCTAssertFalse(buffer.isLoaded(range: 9 ..< 20))
    }

    func testAppendFillsPagesInOrder() {
        var buffer = RowBuffer(pageSize: 4)
        buffer.append(makeRows(0 ..< 3), startingAt: 0)
        buffer.append(makeRows(3 ..< 10), startingAt: 3)
        for index in 0 ..< 10 {
            XCTAssertEqual(buffer.row(at: index)?.first, .int(Int64(index)), "row \(index)")
        }
        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.loadedPages, [0, 1, 2])
    }

    func testAppendKeepsIndicesExactAcrossBatchBoundaries() {
        var buffer = RowBuffer(pageSize: 500)
        var cursor = 0
        // Batches that do not divide evenly into pages, as a real stream produces.
        for size in [500, 137, 500, 363, 1] {
            buffer.append(makeRows(cursor ..< cursor + size), startingAt: cursor)
            cursor += size
        }
        for index in stride(from: 0, to: cursor, by: 37) {
            XCTAssertEqual(buffer.row(at: index)?.first, .int(Int64(index)), "row \(index)")
        }
        XCTAssertEqual(buffer.count, cursor)
    }

    func testReplaceRowInPlace() {
        var buffer = RowBuffer(pageSize: 10)
        buffer.store(page: 0, rows: makeRows(0 ..< 10))
        buffer.replaceRow(at: 4, with: [.int(99), .string("changed")])
        XCTAssertEqual(buffer.row(at: 4)?.first, .int(99))
        // Replacing into a page that is not loaded is ignored rather than corrupting.
        buffer.replaceRow(at: 400, with: [.int(1)])
        XCTAssertNil(buffer.row(at: 400))
    }

    /// SPEC §12.1: at most 200,000 rows in memory, with pages near the viewport kept.
    func testEvictionRespectsTheCapAndKeepsTheViewport() {
        var buffer = RowBuffer(pageSize: 1_000, rowCapacity: 10_000, residentPageRadius: 2)
        for page in 0 ..< 20 {
            buffer.noteViewport(page: page)
            buffer.store(page: page, rows: makeRows(page * 1_000 ..< (page + 1) * 1_000))
        }
        XCTAssertLessThanOrEqual(buffer.count, 10_000)
        // The viewport's neighbourhood survived.
        for page in 17 ... 19 {
            XCTAssertTrue(buffer.loadedPages.contains(page), "page \(page) should still be resident")
        }
        // Something far away did not.
        XCTAssertFalse(buffer.loadedPages.contains(0))
    }

    func testEvictionPrefersPagesFurthestFromTheViewport() {
        var buffer = RowBuffer(pageSize: 100, rowCapacity: 300, residentPageRadius: 0)
        buffer.store(page: 0, rows: makeRows(0 ..< 100))
        buffer.store(page: 50, rows: makeRows(5_000 ..< 5_100))
        buffer.store(page: 51, rows: makeRows(5_100 ..< 5_200))
        buffer.noteViewport(page: 51)
        buffer.store(page: 52, rows: makeRows(5_200 ..< 5_300))
        XCTAssertFalse(buffer.loadedPages.contains(0), "the distant page should go first")
        XCTAssertTrue(buffer.loadedPages.contains(51))
    }

    func testRemoveAll() {
        var buffer = RowBuffer(pageSize: 10)
        buffer.store(page: 0, rows: makeRows(0 ..< 10))
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }
}

final class EditBufferTests: XCTestCase {
    let identity: [String: DBValue] = ["id": .int(7)]

    func testEditsShowThroughTheOverlay() {
        var buffer = EditBuffer()
        XCTAssertTrue(buffer.isEmpty)
        buffer.setValue(.string("new"), row: 0, column: "name", loaded: .string("old"), identity: identity)
        XCTAssertEqual(buffer.value(row: 0, column: "name", loaded: .string("old")), .string("new"))
        XCTAssertEqual(buffer.state(row: 0, column: "name"), .edited)
        XCTAssertEqual(buffer.state(row: 0, column: "other"), .unchanged)
        XCTAssertEqual(buffer.pendingStatementCount, 1)
    }

    func testSettingACellBackToItsLoadedValueClearsTheEdit() {
        var buffer = EditBuffer()
        buffer.setValue(.string("new"), row: 0, column: "name", loaded: .string("old"), identity: identity)
        buffer.setValue(.string("old"), row: 0, column: "name", loaded: .string("old"), identity: identity)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.state(row: 0, column: "name"), .unchanged)
    }

    func testDeletionSupersedesEdits() {
        var buffer = EditBuffer()
        buffer.setValue(.string("new"), row: 3, column: "name", loaded: .string("old"), identity: identity)
        buffer.markDeleted(row: 3, identity: identity)
        XCTAssertEqual(buffer.rowState(3), .deleted)
        XCTAssertEqual(buffer.state(row: 3, column: "name"), .deleted)
        XCTAssertEqual(buffer.pendingStatementCount, 1)

        buffer.unmarkDeleted(row: 3)
        XCTAssertEqual(buffer.rowState(3), .unchanged)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testInserts() {
        var buffer = EditBuffer()
        let insert = buffer.addInsert()
        buffer.setInsertValue(.string("a"), id: insert.id, column: "name")
        XCTAssertEqual(buffer.pendingInserts.count, 1)
        XCTAssertEqual(buffer.pendingInserts.first?.values["name"], .string("a"))
        buffer.removeInsert(id: insert.id)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDiscardRestoresEverything() {
        var buffer = EditBuffer()
        buffer.setValue(.int(1), row: 0, column: "a", loaded: .int(0), identity: identity)
        buffer.markDeleted(row: 1, identity: identity)
        buffer.addInsert()
        XCTAssertEqual(buffer.pendingStatementCount, 3)
        buffer.discardAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.value(row: 0, column: "a", loaded: .int(0)), .int(0))
    }

    /// SPEC §12.6: three cells across two rows commit as exactly two UPDATE statements.
    func testStatementsForTheAcceptanceScenario() throws {
        var buffer = EditBuffer()
        let first: [String: DBValue] = ["id": .int(1)]
        let second: [String: DBValue] = ["id": .int(2)]
        buffer.setValue(.string("a"), row: 0, column: "name", loaded: .string("x"), identity: first)
        buffer.setValue(.int(30), row: 0, column: "age", loaded: .int(29), identity: first)
        buffer.setValue(.string("b"), row: 1, column: "name", loaded: .string("y"), identity: second)

        let generator = DMLGenerator(
            dialect: .postgresql,
            table: TableRef(database: "app", schema: "public", name: "users"),
            identityColumns: ["id"]
        )
        let statements = try buffer.statements(using: generator)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements.allSatisfy { $0.kind == .update })
        XCTAssertEqual(statements[0].parameters, [.int(30), .string("a"), .int(1)])
        XCTAssertEqual(statements[1].parameters, [.string("b"), .int(2)])
    }

    func testStatementOrderIsUpdatesThenDeletesThenInserts() throws {
        var buffer = EditBuffer()
        buffer.addInsert(PendingInsert(values: ["name": .string("new")]))
        buffer.markDeleted(row: 5, identity: ["id": .int(5)])
        buffer.setValue(.string("edited"), row: 1, column: "name", loaded: .string("x"), identity: ["id": .int(1)])

        let generator = DMLGenerator(
            dialect: .postgresql,
            table: TableRef(database: "app", schema: "public", name: "users"),
            identityColumns: ["id"]
        )
        XCTAssertEqual(try buffer.statements(using: generator).map(\.kind), [.update, .delete, .insert])
    }
}
