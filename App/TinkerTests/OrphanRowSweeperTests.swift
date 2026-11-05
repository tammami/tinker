import AppKit
import XCTest

@testable import Tinker

/// A row view the outline no longer tracks is removed; the outline's own rows, and what it
/// keeps hidden for reuse, are left alone.
@MainActor
final class OrphanRowSweeperTests: XCTestCase {
    private final class Source: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let items = ["alpha", "beta", "gamma"]

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? items.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            items[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTextField(labelWithString: item as? String ?? "")
        }
    }

    private var window: NSWindow!
    private var source: Source!
    private var outline: NSOutlineView!
    private var container: NSView!

    override func setUp() async throws {
        source = Source()
        outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        outline.dataSource = source
        outline.delegate = source
        container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        container.addSubview(outline)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()
        for row in 0 ..< outline.numberOfRows { _ = outline.rowView(atRow: row, makeIfNecessary: true) }
    }

    override func tearDown() async throws {
        window.close()
    }

    private func addRowView(hidden: Bool = false) -> NSTableRowView {
        let view = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 17))
        view.isHidden = hidden
        outline.addSubview(view)
        return view
    }

    private var trackedRows: [NSTableRowView] {
        (0 ..< outline.numberOfRows).compactMap { outline.rowView(atRow: $0, makeIfNecessary: false) }
    }

    /// What was on screen in the bug: a visible row view sitting over a tracked one, which
    /// the outline answers -1 for.
    func testAVisibleRowViewTheOutlineDoesNotTrackIsRemoved() throws {
        let orphan = addRowView()
        XCTAssertEqual(outline.row(for: orphan), -1)

        XCTAssertEqual(OrphanRowSweeper.sweep(outline), 1)

        XCTAssertNil(orphan.superview)
    }

    func testTheOutlinesOwnRowsAreKept() throws {
        let rows = trackedRows
        XCTAssertEqual(rows.count, 3)

        XCTAssertEqual(OrphanRowSweeper.sweep(outline), 0)

        for row in rows { XCTAssertTrue(row.superview === outline) }
        XCTAssertEqual(trackedRows.count, 3)
    }

    /// A hidden row view is the outline's reuse pool, not something left on screen.
    func testAHiddenRowViewIsLeftForTheOutline() throws {
        let pooled = addRowView(hidden: true)

        XCTAssertEqual(OrphanRowSweeper.sweep(outline), 0)

        XCTAssertTrue(pooled.superview === outline)
    }

    /// Sweeping happens beside the list, from an anchor that is the list's sibling.
    func testTheOutlineIsFoundFromASibling() throws {
        let anchor = NSView()
        container.addSubview(anchor)

        XCTAssertTrue(OrphanRowSweeper.nearestOutline(to: anchor) === outline)
    }

    /// A view with no outline around it finds nothing rather than another window's.
    func testNoOutlineIsFoundFromAnUnrelatedView() throws {
        let parent = NSView()
        let anchor = NSView()
        parent.addSubview(anchor)

        XCTAssertNil(OrphanRowSweeper.nearestOutline(to: anchor))
    }
}
