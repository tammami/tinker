import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import XCTest

@testable import Tinker

/// The real grid — `DataGridView` hosting its `NSTableView` in a window — measured, not
/// eyeballed (SPEC §12.6, ADR-0047). The package suite measures the model; this measures
/// the drawing: a reload and a scroll across a large result must each fit a frame.
@MainActor
final class DataGridPerformanceTests: XCTestCase {
    static let rows = 100_000
    static let columns = 20
    /// One frame at 60 Hz. The budget the spec puts on scrolling and on a reload.
    static let frameBudget: Duration = .milliseconds(16)

    /// The grid in a window, laid out once. Kept for the test's duration by the caller.
    private struct Hosted {
        let window: NSWindow
        let hosting: NSHostingView<DataGridView>
        let model: GridModel
        let table: NSTableView
        let scrollView: NSScrollView
    }

    private func host() throws -> Hosted {
        let model = Self.makeModel()
        let hosting = NSHostingView(
            rootView: DataGridView(model: model, selection: .constant(GridSelection()), revision: 0))
        hosting.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI build the AppKit tree and lay it out once before anything is timed.
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let table = Self.firstTableView(in: hosting) else {
            throw XCTSkip("the hosted grid built no table view; the view hierarchy changed")
        }
        guard let scrollView = table.enclosingScrollView else { throw XCTSkip("the table has no scroll view") }
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return Hosted(window: window, hosting: hosting, model: model, table: table, scrollView: scrollView)
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = firstTableView(in: child) { return found }
        }
        return nil
    }

    /// A result the size the spec talks about, built in memory so the measurement is of
    /// the view alone.
    private static func makeModel() -> GridModel {
        let columns = (0 ..< Self.columns).map { index in
            ColumnMeta(id: index, name: "column_\(index)", nativeTypeName: index == 0 ? "int8" : "text", kind: index == 0 ? .int : .string)
        }
        let model = GridModel(source: .query("SELECT * FROM big_table"), dialect: .postgresql, loader: EmptyLoader(), columns: columns)
        let batchSize = 5_000
        var start = 0
        while start < Self.rows {
            let rows = (start ..< min(start + batchSize, Self.rows)).map { row in
                (0 ..< Self.columns).map { column -> DBValue in
                    column == 0 ? .int(Int64(row)) : .string("row \(row) col \(column)")
                }
            }
            model.appendStreamed(columns: columns, batch: RowBatch(rows: rows, startIndex: start))
            start += rows.count
        }
        model.markStreamComplete()
        return model
    }

    func testTheHostedTableHoldsEveryRow() throws {
        let table = try host().table
        XCTAssertEqual(table.numberOfRows, Self.rows)
        XCTAssertEqual(table.numberOfColumns, Self.columns + 1, "every column, plus the row-number gutter")
    }

    /// The reload a revision bump does — a page arrived, a cell was edited — plus the
    /// redraw of the visible rows, through the coordinator, as the app does it.
    func testAReloadFitsAFrame() throws {
        let table = try host().table
        guard let coordinator = (table as? GridTableView)?.controller else {
            throw XCTSkip("the hosted table has no coordinator; the view hierarchy changed")
        }
        var total: Duration = .zero
        let iterations = 10
        for _ in 0 ..< iterations {
            let clock = ContinuousClock()
            total += clock.measure {
                coordinator.reloadAfterRevision()
                table.displayIfNeeded()
            }
        }
        let average = total / iterations
        XCTAssertLessThan(average, Self.frameBudget, "a reload averaged \(average); the spec allows one frame")
        measure(metrics: [XCTClockMetric()]) {
            coordinator.reloadAfterRevision()
            table.displayIfNeeded()
        }
    }

    /// The reload that changes the columns has to make every view again; it is the
    /// slow path, and it stays within a few frames.
    func testAFullReloadStaysWithinAFewFrames() throws {
        let table = try host().table
        var total: Duration = .zero
        let iterations = 10
        for _ in 0 ..< iterations {
            let clock = ContinuousClock()
            total += clock.measure {
                table.reloadData()
                table.displayIfNeeded()
            }
        }
        let average = total / iterations
        XCTAssertLessThan(average, Self.frameBudget * 3, "a full reload averaged \(average)")
    }

    /// Jumping through the result the way a scrollbar drag does: each stop lays out and
    /// draws a screen of rows nobody has seen yet.
    func testScrollingThroughTheResultFitsAFrame() throws {
        let hosted = try host()
        let table = hosted.table
        let scrollView = hosted.scrollView
        let stops = stride(from: 0, to: Self.rows, by: Self.rows / 40).map { $0 }
        var slowest: Duration = .zero
        var total: Duration = .zero
        for row in stops {
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                let origin = NSPoint(x: 0, y: table.rect(ofRow: row).minY)
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                table.displayIfNeeded()
            }
            slowest = max(slowest, elapsed)
            total += elapsed
        }
        let average = total / stops.count
        XCTAssertLessThan(average, Self.frameBudget, "a scroll stop averaged \(average); the spec allows one frame")
        XCTAssertLessThan(slowest, Self.frameBudget * 4, "the slowest stop took \(slowest)")
        measure(metrics: [XCTClockMetric()]) {
            for row in stops {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                table.displayIfNeeded()
            }
        }
    }
}
