import AppKit
import DBCore
import DBGrid
import DBSQLite
import SwiftUI
import XCTest

@testable import Tinker

/// Editing a row through the inspector's Row pane, on the real table tab in a window. The
/// pane and the selected row stay where they were.
///
/// Runs on a SQLite file of its own and a throwaway store, so it reaches no server. Which field
/// holds the keyboard cannot be tested here: the test host is not the active app, so SwiftUI's
/// focus state does not move. That was checked by hand.
@MainActor
final class InspectorStaysPutTests: XCTestCase {
    private var directory: URL!
    private var environment: AppEnvironment!
    private var config: ConnectionConfig!
    private var controller: TableTabController!
    private var query: QueryTabController!
    private var window: NSWindow!
    private var hosting: NSHostingView<AnyView>!

    /// Seeds the database and returns the table.
    private func prepare(production: Bool) async throws -> TableRef {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-inspector-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = AppEnvironment(
            secrets: EphemeralSecretStore(), storePath: directory.appendingPathComponent("store.sqlite").path)
        await environment.load()
        config = ConnectionConfig(
            name: "inspector-test", dialect: .sqlite, host: "", port: 0, user: "",
            database: directory.appendingPathComponent("data.sqlite").path,
            options: [SQLiteDriver.OptionKey.createIfMissing: "true"], isProduction: production)
        await environment.save(config)
        let session = try XCTUnwrap(environment.session(for: config.id))
        _ = try await session.connect()
        try await session.withLease { connection in
            _ = try await connection.executeCollecting(
                "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, note TEXT)")
            for id in 1 ... 9 {
                _ = try await connection.executeCollecting("INSERT INTO items VALUES (\(id), 'row \(id)', 'note \(id)')")
            }
        }
        return TableRef(database: "main", schema: "main", name: "items")
    }

    private func open(production: Bool) async throws {
        let table = try await prepare(production: production)
        controller = TableTabController(
            table: table, connectionID: config.id, dialect: .sqlite, environment: environment)
        await controller.start()
        let tab = WorkspaceTab(kind: .table(table), connectionID: config.id, title: "items")
        tab.isInspectorVisible = true
        try await show(
            AnyView(
                TableTabView(controller: controller, workspace: WorkspaceModel(environment: environment), tab: tab)))
        // Row 5 selected from the gutter, with the Row pane open, as reported.
        controller.gridDidChangeSelection(GridSelection(row: 4, column: 0, mode: .rows))
        try await openRowPane()
    }

    /// The same on a query tab, with the row picked from a result of the table.
    private func openQuery(production: Bool) async throws {
        _ = try await prepare(production: production)
        query = QueryTabController(connectionID: config.id, dialect: .sqlite, environment: environment)
        query.sql = "SELECT id, name, note FROM items ORDER BY id"
        query.caretOffset = 0
        query.run(all: true)
        for _ in 0 ..< 500 {
            if !query.isRunning, query.results.first?.statement == query.sql { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(query.results.first?.grid?.isEditable, true)
        let tab = WorkspaceTab(kind: .query, connectionID: config.id, title: "SQL 1")
        tab.isInspectorVisible = true
        try await show(
            AnyView(
                QueryTabView(
                    controller: query, workspace: WorkspaceModel(environment: environment), tab: tab,
                    fontName: "Menlo", fontSize: 13, settings: AppSettings(environment: environment))))
        query.gridDidChangeSelection(GridSelection(row: 4, column: 0, mode: .rows))
        try await openRowPane()
    }

    private func show(_ view: AnyView) async throws {
        hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try await settle()
    }

    private func openRowPane() async throws {
        try await settle()
        let picker = try paneControl()
        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        try await settle()
        XCTAssertNotNil(field(showing: "row 5"), "the form shows row 5")
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        await query?.releaseHeldConnection()
        if let config, let environment {
            for session in environment.sessions(for: config.id) { await session.disconnect() }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Lets the views and the writes have their turn.
    private func settle() async throws {
        for _ in 0 ..< 6 {
            hosting?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// The inspector's Cell/Row control: the rightmost two-segment control on the tab.
    private func paneControl() throws -> NSSegmentedControl {
        let controls = views(of: NSSegmentedControl.self, in: hosting).filter { $0.segmentCount == 2 }
        return try XCTUnwrap(
            controls.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
    }

    private func field(showing text: String) -> NSTextField? {
        views(of: NSTextField.self, in: hosting).first { $0.isEditable && $0.stringValue == text }
    }

    private var isRowPaneOpen: Bool { (try? paneControl().selectedSegment) == 1 }

    private func committed(_ column: String, id: Int) async throws -> String? {
        let session = try XCTUnwrap(environment.session(for: config.id))
        let result = try await session.withLease { connection in
            try await connection.executeCollecting("SELECT \(column) FROM items WHERE id = \(id)")
        }
        return result.firstText
    }

    private func assertStillOnRowFive(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isRowPaneOpen, "the pane went back to Cell", file: file, line: line)
        XCTAssertEqual(controller.selection.focusRow, 4, file: file, line: line)
        XCTAssertEqual(controller.selection.mode, .rows, "the row stays selected", file: file, line: line)
    }

    func testAnAutoCommittedEditLeavesThePaneAndTheRow() async throws {
        try await open(production: false)

        controller.gridDidCommitEdit(row: 4, column: 1, text: "edited")
        try await settle()

        let written = try await committed("name", id: 5)
        XCTAssertEqual(written, "edited")
        assertStillOnRowFive()
    }

    /// On production the edit waits for the commit sheet; neither step moves anything.
    func testOnProductionNeitherTheEditNorItsCommitMovesThePaneOrTheRow() async throws {
        try await open(production: true)

        controller.gridDidCommitEdit(row: 4, column: 1, text: "edited")
        try await settle()
        let waiting = try await committed("name", id: 5)
        XCTAssertEqual(waiting, "row 5", "nothing is written until the sheet")
        XCTAssertEqual(controller.model?.edits.pendingStatementCount, 1)
        assertStillOnRowFive()

        _ = await controller.commit()
        try await settle()
        let written = try await committed("name", id: 5)
        XCTAssertEqual(written, "edited")
        assertStillOnRowFive()
    }

    func testOnAQueryTabAnAutoCommittedEditLeavesThePaneAndTheRow() async throws {
        try await openQuery(production: false)

        query.gridDidCommitEdit(row: 4, column: 1, text: "edited")
        try await settle()

        let written = try await committed("name", id: 5)
        XCTAssertEqual(written, "edited")
        XCTAssertTrue(isRowPaneOpen, "the pane went back to Cell")
        XCTAssertEqual(query.selection.focusRow, 4)
        XCTAssertEqual(query.selection.mode, .rows)
    }

    func testOnAProductionQueryTabNeitherTheEditNorItsCommitMovesThePaneOrTheRow() async throws {
        try await openQuery(production: true)

        query.gridDidCommitEdit(row: 4, column: 1, text: "edited")
        try await settle()
        XCTAssertEqual(query.pendingEditCount, 1)
        XCTAssertTrue(isRowPaneOpen, "the pane went back to Cell")

        _ = await query.commitEdits()
        try await settle()

        let written = try await committed("name", id: 5)
        XCTAssertEqual(written, "edited")
        XCTAssertFalse(query.isInTransaction)
        XCTAssertTrue(isRowPaneOpen, "the pane went back to Cell")
        XCTAssertEqual(query.selection.focusRow, 4)
        XCTAssertEqual(query.selection.mode, .rows)
    }

    /// Types into a form field the way the keyboard does, without leaving it.
    private func type(_ text: String, into field: NSTextField) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.moveToEndOfDocument(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// The form follows the selection to another row with what was typed still in a field.
    /// It goes to the row it was typed for, not the one now shown, and is not dropped.
    func testWhatWasTypedGoesToItsOwnRowWhenTheSelectionMoves() async throws {
        try await open(production: false)
        try type(" edited", into: try XCTUnwrap(field(showing: "row 5")))
        try await settle()

        controller.gridDidChangeSelection(GridSelection(row: 6, column: 1))
        try await settle()

        let onFive = try await committed("name", id: 5)
        let onSeven = try await committed("name", id: 7)
        XCTAssertEqual(onFive, "row 5 edited", "the typed value was lost")
        XCTAssertEqual(onSeven, "row 7", "written over a row nobody edited")
        XCTAssertNotNil(field(showing: "row 7"), "the form now shows row 7")
    }

    /// On production it waits for the commit sheet, on the row it was typed for.
    func testOnProductionWhatWasTypedWaitsOnItsOwnRow() async throws {
        try await open(production: true)
        try type(" edited", into: try XCTUnwrap(field(showing: "row 5")))
        try await settle()

        controller.gridDidChangeSelection(GridSelection(row: 6, column: 1))
        try await settle()

        XCTAssertEqual(controller.model?.edits.pendingStatementCount, 1)
        XCTAssertEqual(controller.model?.value(row: 4, column: 1), .string("row 5 edited"))
        XCTAssertEqual(controller.model?.value(row: 6, column: 1), .string("row 7"))
        let onFive = try await committed("name", id: 5)
        XCTAssertEqual(onFive, "row 5", "nothing is written until the sheet")
    }

    /// An untouched form writes nothing as the selection moves through it.
    func testMovingThroughRowsWithNothingTypedWritesNothing() async throws {
        try await open(production: true)

        controller.gridDidChangeSelection(GridSelection(row: 6, column: 1))
        try await settle()
        controller.gridDidChangeSelection(GridSelection(row: 2, column: 1))
        try await settle()

        XCTAssertEqual(controller.model?.edits.pendingStatementCount, 0)
    }
}
