import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import XCTest

@testable import Tinker

/// Add Row on the real grid in a window, on a table far longer than the screen: the new row
/// comes into view and can be typed in straight away, with no scrolling and no click.
@MainActor
final class GridAddRowTests: XCTestCase {
    private struct NineHundredRows: GridDataLoader {
        func loadPage(_ request: PageRequest) async throws -> LoadedPage {
            LoadedPage(
                columns: [
                    ColumnMeta(id: 0, name: "id", nativeTypeName: "integer", kind: .int, isPrimaryKey: true),
                    ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
                ],
                rows: (0 ..< 900).map { [.int(Int64($0)), .string("row \($0)")] })
        }

        func exactCount(filter: [FilterRule]) async throws -> Int64 { 900 }
    }

    private final class Recorder: DataGridDelegate {
        var commits: [(row: Int, column: Int, text: String)] = []
        func gridDidCommitEdit(row: Int, column: Int, text: String) { commits.append((row, column, text)) }
        func gridDidChangeSelection(_ selection: GridSelection) {}
        func gridDidRequestLoad(range: Range<Int>) {}
        func gridDidRequestInspector() {}
        func gridDidChangeColumnWidths(_ widths: [String: Double]) {}
        func gridDidRequestCopy(format: ClipboardFormat) {}
        func gridDidRequestUndo() {}
        func gridDidRequestRedo() {}
        func gridCanUndo() -> Bool { false }
        func gridCanRedo() -> Bool { false }
    }

    private var window: NSWindow!
    private var hosting: NSHostingView<DataGridView>!
    private var model: GridModel!
    private var table: NSTableView!
    private var coordinator: GridCoordinator!
    private var recorder: Recorder!
    private var revision = 0

    override func setUp() async throws {
        model = GridModel(source: .query("SELECT id, name FROM items"), dialect: .sqlite, loader: NineHundredRows())
        await model.load(page: 0)
        model.editTarget = TableRef(database: "main", schema: "main", name: "items")
        model.setIdentity(columns: ["id"], kind: .int)
        XCTAssertTrue(model.isEditable)
        recorder = Recorder()
        hosting = NSHostingView(rootView: gridView(selection: GridSelection()))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle()
        table = try XCTUnwrap(Self.firstTableView(in: hosting))
        coordinator = try XCTUnwrap((table as? GridTableView)?.controller)
        XCTAssertEqual(table.numberOfRows, 900)
        XCTAssertLessThan(table.visibleRect.maxY, table.rect(ofRow: 899).minY, "it starts at the top")
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.close()
    }

    private func gridView(selection: GridSelection) -> DataGridView {
        DataGridView(model: model, selection: .constant(selection), revision: revision, delegate: recorder)
    }

    private func settle() {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTableView(in: $0) }.first
    }

    /// What the controllers do on Add Row: add it, put the focus on it, ask for an update.
    private func addRow() {
        XCTAssertNotNil(model.addRow())
        revision += 1
        hosting.rootView = gridView(selection: GridSelection(row: model.displayRowCount - 1, column: 1))
        settle()
    }

    private var lastRow: Int { model.displayRowCount - 1 }

    /// The row is on screen, with nothing to scroll.
    func testAddRowBringsTheNewRowIntoView() throws {
        addRow()

        XCTAssertEqual(lastRow, 900)
        XCTAssertEqual(table.numberOfRows, 901)
        XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: lastRow)))
    }

    /// The cursor is in the new row's cell, and what is typed next goes there: no click.
    func testAddRowOpensTheCellSoTypingGoesIntoIt() throws {
        addRow()

        let editor = try XCTUnwrap(coordinator.inlineEditor, "no editor opened")
        XCTAssertEqual(table.row(for: editor), lastRow)
        let field = try XCTUnwrap(window.firstResponder as? NSTextView, "the keyboard is not in the cell")
        XCTAssertTrue(field.delegate === editor)

        field.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.stringValue, "typed")
    }

    /// A second Add Row while still typing in the first: what was typed is kept, and the
    /// cursor moves on. The button takes no focus, so the editor used to stay behind.
    func testASecondAddRowKeepsWhatWasTypedAndMovesOn() throws {
        addRow()
        let first = lastRow
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.insertText("first", replacementRange: NSRange(location: 0, length: 0))

        addRow()

        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.commits.first?.row, first)
        XCTAssertEqual(recorder.commits.first?.text, "first")
        let editor = try XCTUnwrap(coordinator.inlineEditor)
        XCTAssertEqual(table.row(for: editor), lastRow)
        XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: lastRow)))
    }

    /// A focus moved to an existing row must not commit a half-typed cell on its own.
    func testOnlyAPendingNewRowTakesTheFocusFromAnOpenEditor() {
        let rule = GridCoordinator.leavesEditorBehind
        XCTAssertTrue(rule((900, 1), (901, 1), true))
        XCTAssertFalse(rule((900, 1), (900, 1), true), "the same cell")
        XCTAssertFalse(rule((3, 1), (0, 0), false), "an existing row")
    }

    /// A hidden column has no cell to open, so typing starts in the first one shown.
    func testTypingStartsInTheFirstColumnShown() {
        let first = TableTabController.firstShownColumn
        XCTAssertEqual(first(["id", "name"], []), 0)
        XCTAssertEqual(first(["id", "name"], ["id"]), 1)
        XCTAssertEqual(first(["id"], ["id"]), 0, "nothing shown")
    }
}
