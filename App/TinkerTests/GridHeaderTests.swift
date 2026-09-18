import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import XCTest

@testable import Tinker

/// The grid's header in a real window: the widths it starts from, and the divider under
/// the pointer (SPEC §12.4, ADR-0056).
@MainActor
final class GridHeaderTests: XCTestCase {
    /// A delegate that remembers widths the way a table tab does.
    private final class WidthDelegate: DataGridDelegate {
        var stored: [String: Double]
        private(set) var reported: [[String: Double]] = []

        init(stored: [String: Double]) { self.stored = stored }

        func gridStoredColumnWidths() -> [String: Double] { stored }
        func gridDidChangeColumnWidths(_ widths: [String: Double]) {
            stored = widths
            reported.append(widths)
        }
        func gridDidChangeSelection(_ selection: GridSelection) {}
        func gridDidRequestLoad(range: Range<Int>) {}
        func gridDidCommitEdit(row: Int, column: Int, text: String) {}
        func gridDidRequestInspector() {}
        func gridDidRequestCopy(format: ClipboardFormat) {}
        func gridDidRequestDeleteRows() {}
        func gridDidRequestAddRow() {}
        func gridDidRequestUndo() {}
        func gridDidRequestRedo() {}
        func gridCanUndo() -> Bool { false }
        func gridCanRedo() -> Bool { false }
    }

    private struct Hosted {
        let window: NSWindow
        let table: NSTableView
        let header: GridHeaderView
        let delegate: WidthDelegate
    }

    private func host(widths: [String: Double] = [:]) throws -> Hosted {
        let columns = (0 ..< 4).map {
            ColumnMeta(id: $0, name: "column_\($0)", nativeTypeName: "text", kind: .string)
        }
        let model = GridModel(
            source: .query("SELECT 1"), dialect: .postgresql, loader: EmptyLoader(), columns: columns)
        model.appendStreamed(
            columns: columns,
            batch: RowBatch(
                rows: (0 ..< 5).map { row in columns.map { _ in DBValue.string("row \(row)") } }, startIndex: 0))
        model.markStreamComplete()
        let delegate = WidthDelegate(stored: widths)
        let hosting = NSHostingView(
            rootView: DataGridView(
                model: model, selection: .constant(GridSelection()), revision: 0, delegate: delegate))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let table = Self.firstTableView(in: hosting), let header = table.headerView as? GridHeaderView else {
            throw XCTSkip("the hosted grid built no header; the view hierarchy changed")
        }
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return Hosted(window: window, table: table, header: header, delegate: delegate)
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = firstTableView(in: child) { return found }
        }
        return nil
    }

    /// Moves the pointer over the header without touching the real one.
    private func moveMouse(to point: NSPoint, in hosted: Hosted) {
        let inWindow = hosted.header.convert(point, to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return XCTFail("no event") }
        hosted.header.mouseMoved(with: event)
    }

    /// The widths a tab remembers reach the columns by being asked for, not by being
    /// handed to the view: what the view reads it also re-renders for, and mid-drag that
    /// rebuilt the header's tracking areas sixty times a second (ADR-0056).
    func testTheRememberedWidthsAreAskedForWhenTheColumnsAreBuilt() throws {
        let hosted = try host(widths: ["column_1": 313, "column_2": 211])
        let byName = Dictionary(
            uniqueKeysWithValues: hosted.table.tableColumns.map { ($0.identifier.rawValue, $0.width) })
        XCTAssertEqual(byName["column_1"], 313)
        XCTAssertEqual(byName["column_2"], 211)
        XCTAssertNotNil(byName["column_0"], "a column with nothing remembered still gets its default")
    }

    /// Every divider but the gutter's is a handle, and the pointer finds it from either side.
    func testThePointerOnADividerLightsItUp() throws {
        let hosted = try host()
        let header = hosted.header
        let edges = header.resizeEdges()
        XCTAssertEqual(edges.count, 4, "one handle per column, and none for the row gutter")

        let middle = header.bounds.height / 2
        moveMouse(to: NSPoint(x: edges[0].x, y: middle), in: hosted)
        XCTAssertEqual(header.hoveredEdge, 0, "right on the line")

        moveMouse(to: NSPoint(x: edges[1].x - GridHeaderView.resizeTolerance + 1, y: middle), in: hosted)
        XCTAssertEqual(header.hoveredEdge, 1, "a few points short of the line still counts")

        moveMouse(to: NSPoint(x: edges[1].x + GridHeaderView.resizeTolerance - 1, y: middle), in: hosted)
        XCTAssertEqual(header.hoveredEdge, 1, "and a few points past it")

        let heading = (edges[0].x + edges[1].x) / 2
        moveMouse(to: NSPoint(x: heading, y: middle), in: hosted)
        XCTAssertNil(header.hoveredEdge, "the middle of a heading is for sorting, not resizing")
    }

    /// A press that moved is a drag, not a click. AppKit reports both as `didClick`, and a
    /// table tab answers a click by re-sorting and fetching the page again: a missed grab
    /// at a divider used to throw the rows the user was aiming at across the screen, while
    /// the same slip in a query tab — which ignores the click — cost nothing (ADR-0059).
    func testAPressThatMovedIsNotAClickOnTheHeading() {
        let origin = NSPoint(x: 100, y: 10)
        XCTAssertTrue(GridCoordinator.isClickRatherThanDrag(from: origin, to: origin))
        XCTAssertTrue(
            GridCoordinator.isClickRatherThanDrag(from: origin, to: NSPoint(x: 103, y: 12)),
            "a hand is never perfectly still; three points is still a click")
        XCTAssertFalse(
            GridCoordinator.isClickRatherThanDrag(from: origin, to: NSPoint(x: 104, y: 10)),
            "four points is the slip that used to re-sort the table")
        XCTAssertFalse(GridCoordinator.isClickRatherThanDrag(from: origin, to: NSPoint(x: 160, y: 10)))
        XCTAssertTrue(
            GridCoordinator.isClickRatherThanDrag(from: nil, to: origin),
            "a click the header never saw go down — the keyboard, a test — still sorts")
    }

    /// The drag looks its column up by identifier on every event, so a reload that rebuilt
    /// the columns underneath it cannot strand it.
    func testTheColumnSurvivesARebuildUnderTheDrag() throws {
        let hosted = try host(widths: ["column_1": 200])
        guard let coordinator = (hosted.table as? GridTableView)?.controller else {
            throw XCTSkip("the hosted table has no coordinator")
        }
        let before = hosted.table.tableColumns.first { $0.identifier.rawValue == "column_1" }
        coordinator.rebuildColumns()
        let after = hosted.table.tableColumns.first { $0.identifier.rawValue == "column_1" }
        XCTAssertNotNil(after)
        XCTAssertFalse(before === after, "a rebuild makes new columns, which is why the drag looks its own up")
        XCTAssertEqual(after?.width, 200, "and the remembered width survives it")
    }
}

/// Whether an observation fired, across the isolation boundary `onChange` is called on.
private final class Notified: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

/// A width written during a drag must not be something a view reads.
@MainActor
final class TableTabWidthObservationTests: XCTestCase {
    private func controller() -> TableTabController {
        TableTabController(
            table: TableRef(database: "tinker_test", schema: "public", name: "orders"),
            connectionID: UUID(),
            dialect: .postgresql,
            environment: AppEnvironment(secrets: EphemeralSecretStore())
        )
    }

    /// The measurement behind ADR-0056: reading the widths in the tab's body meant one
    /// full SwiftUI update per mouse-move, which threw the header's tracking areas away
    /// as fast as they were made. Nothing observes them now.
    func testAWidthWrittenDuringADragNotifiesNobody() {
        let tab = controller()
        let notified = Notified()
        withObservationTracking {
            _ = tab.columnWidths
        } onChange: {
            notified.fire()
        }
        tab.gridDidChangeColumnWidths(["id": 120])
        XCTAssertFalse(notified.didFire, "a drag writes this sixty times a second; no view may re-render for it")
        XCTAssertEqual(tab.gridStoredColumnWidths(), ["id": 120], "the grid still gets them when it asks")
    }

    /// The other grid preferences still drive the view: hiding a column must redraw it.
    func testHidingAColumnStillNotifies() {
        let tab = controller()
        let notified = Notified()
        withObservationTracking {
            _ = tab.hiddenColumns
        } onChange: {
            notified.fire()
        }
        tab.hiddenColumns = ["id"]
        XCTAssertTrue(notified.didFire)
    }
}
