import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// What the grid asks the surrounding tab to do.
@MainActor
public protocol DataGridDelegate: AnyObject {
    func gridDidChangeSelection(_ selection: GridSelection)
    func gridDidRequestLoad(range: Range<Int>)
    func gridDidCommitEdit(row: Int, column: Int, text: String)
    func gridDidRequestInspector()
    func gridDidChangeColumnWidths(_ widths: [String: Double])
    /// A click on a column heading. `additive` is true when shift was held, which adds a
    /// secondary sort rather than replacing the first (SPEC §12.4).
    func gridDidClickColumnHeader(column: Int, additive: Bool)
    /// Whether a cell's value points at a row in another table.
    func gridHasReference(row: Int, column: Int) -> Bool
    /// Opens the row a cell's foreign key points at.
    func gridDidRequestFollowReference(row: Int, column: Int)
    /// The context menu's copy, in the chosen format.
    func gridDidRequestCopy(format: ClipboardFormat)
    func gridDidRequestSetNull()
    func gridDidRequestDeleteRows()
    func gridDidRequestAddRow()
    func gridDidRequestAutosize(column: Int)
    /// The header's context menu: hide this column, or bring every hidden one back.
    func gridDidRequestHideColumn(_ column: Int)
    func gridDidRequestShowAllColumns()
}

public extension DataGridDelegate {
    /// Query results are what the statement returned; re-ordering them would mean running
    /// a different statement, so a results grid ignores this.
    func gridDidClickColumnHeader(column: Int, additive: Bool) {}
    func gridHasReference(row: Int, column: Int) -> Bool { false }
    func gridDidRequestFollowReference(row: Int, column: Int) {}
    func gridDidRequestSetNull() {}
    func gridDidRequestDeleteRows() {}
    func gridDidRequestAddRow() {}
    func gridDidRequestAutosize(column: Int) {}
    func gridDidRequestHideColumn(_ column: Int) {}
    func gridDidRequestShowAllColumns() {}
}

/// The data grid: an `NSTableView` in an `NSScrollView`, wrapped for SwiftUI.
///
/// One implementation serves both table tabs and query results; editing is enabled only
/// when the model says the rows can be identified (SPEC §12).
public struct DataGridView: NSViewRepresentable {
    public let model: GridModel
    @Binding public var selection: GridSelection
    public let columnWidths: [String: Double]
    /// Columns left out of the table, by name. The model keeps them; only the view skips them.
    public let hiddenColumns: Set<String>
    public weak var delegate: (any DataGridDelegate)?
    /// Bumped by the owner whenever the model's contents changed, so the view reloads.
    public let revision: Int

    public init(
        model: GridModel,
        selection: Binding<GridSelection>,
        columnWidths: [String: Double] = [:],
        hiddenColumns: Set<String> = [],
        revision: Int,
        delegate: (any DataGridDelegate)? = nil
    ) {
        self.model = model
        _selection = selection
        self.columnWidths = columnWidths
        self.hiddenColumns = hiddenColumns
        self.revision = revision
        self.delegate = delegate
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.controller = context.coordinator
        tableView.setAccessibilityIdentifier("result-grid")
        // Uniform row heights are what make a million rows scrollable; automatic heights
        // would measure every row (SPEC §12).
        tableView.rowHeight = DesignTokens.Metrics.gridRowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.gridStyleMask = []
        // The cells draw their own column separators at their trailing edge, and the
        // header draws its at the column boundary. Any horizontal intercell spacing sits
        // between the two, so the body's lines land left of the header's and the grid
        // looks bent. Zero the horizontal gap; the cells carry their own text padding.
        tableView.intercellSpacing = NSSize(width: 0, height: tableView.intercellSpacing.height)
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(GridCoordinator.handleDoubleClick)
        // The header answers right-clicks with Hide Column / Show All Columns.
        let header = GridHeaderView()
        header.controller = context.coordinator
        tableView.headerView = header

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.observeScrolling()
        context.coordinator.rebuildColumns()
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.delegate = delegate
        coordinator.selection = selection
        coordinator.selectionBinding = $selection
        coordinator.storedColumnWidths = columnWidths
        coordinator.hiddenColumns = hiddenColumns
        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.rebuildColumnsIfNeeded()
            coordinator.updateGutterWidth()
            coordinator.updateSortIndicators()
            coordinator.tableView?.reloadData()
        } else {
            coordinator.redrawVisibleCells()
        }
    }

    public func makeCoordinator() -> GridCoordinator {
        GridCoordinator(model: model, selection: selection, delegate: delegate)
    }
}

/// Drives the table view: rows, cells, selection, keyboard and lazy loading.
@MainActor
public final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: GridModel
    var selection: GridSelection
    var selectionBinding: Binding<GridSelection>?
    weak var delegate: (any DataGridDelegate)?
    weak var tableView: GridTableView?
    weak var scrollView: NSScrollView?
    var revision = -1
    var storedColumnWidths: [String: Double] = [:]
    var hiddenColumns: Set<String> = []

    private var builtColumnNames: [String] = []
    /// Kept so the observer's lifetime matches the coordinator's; the notification centre
    /// holds only a weak reference to `self` through the closure.
    private var scrollObserver: (any NSObjectProtocol)?

    init(model: GridModel, selection: GridSelection, delegate: (any DataGridDelegate)?) {
        self.model = model
        self.selection = selection
        self.delegate = delegate
    }

    // MARK: - Columns

    /// The model columns the table shows, in model order.
    var visibleColumnNames: [String] {
        model.columns.map(\.name).filter { !hiddenColumns.contains($0) }
    }

    func rebuildColumnsIfNeeded() {
        guard builtColumnNames != visibleColumnNames else { return }
        rebuildColumns()
    }

    /// Identifies the row gutter, which is a control rather than one of the model's columns.
    static let rowNumberColumnID = NSUserInterfaceItemIdentifier("Tinker.RowNumberColumn")

    /// The model column a table position refers to, or nil when it is the row gutter.
    ///
    /// Columns are reorderable, so a position is not an index into `model.columns`; going
    /// through the identifier is what keeps a click on a moved column honest.
    func modelColumn(atPosition position: Int) -> Int? {
        guard let tableView, tableView.tableColumns.indices.contains(position) else { return nil }
        let identifier = tableView.tableColumns[position].identifier
        guard identifier != Self.rowNumberColumnID else { return nil }
        return model.columns.firstIndex { $0.name == identifier.rawValue }
    }

    /// Where a model column currently sits in the table.
    func position(ofModelColumn index: Int) -> Int? {
        guard let tableView, model.columns.indices.contains(index) else { return nil }
        let name = model.columns[index].name
        return tableView.tableColumns.firstIndex { $0.identifier.rawValue == name }
    }

    /// Wide enough for the highest row number the grid can currently show.
    func gutterWidth() -> CGFloat {
        let digits = max(2, String(max(1, model.displayRowCount)).count)
        return CGFloat(digits) * 8 + 16
    }

    func updateGutterWidth() {
        guard let tableView,
            let gutter = tableView.tableColumns.first(where: { $0.identifier == Self.rowNumberColumnID })
        else { return }
        let width = gutterWidth()
        guard gutter.width != width else { return }
        gutter.minWidth = width
        gutter.maxWidth = width
        gutter.width = width
    }

    func rebuildColumns() {
        guard let tableView else { return }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        // The gutter comes first: a whole-row selection needs something to click on that
        // is not a value, exactly as a spreadsheet's row numbers are (SPEC §12.4).
        let gutter = NSTableColumn(identifier: Self.rowNumberColumnID)
        gutter.headerCell = GridHeaderCell(textCell: "")
        gutter.title = ""
        gutter.width = gutterWidth()
        gutter.minWidth = gutter.width
        gutter.maxWidth = gutter.width
        gutter.resizingMask = []
        tableView.addTableColumn(gutter)

        for meta in model.columns where !hiddenColumns.contains(meta.name) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(meta.name))
            column.headerCell = GridHeaderCell(textCell: meta.name)
            column.title = meta.name
            column.headerToolTip = "\(meta.name) — \(meta.nativeTypeName)"
            column.minWidth = DesignTokens.Metrics.minimumColumnWidth
            column.maxWidth = DesignTokens.Metrics.maximumColumnWidth
            column.width =
                storedColumnWidths[meta.name].map { CGFloat($0) }
                ?? Self.defaultWidth(for: meta)
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        builtColumnNames = visibleColumnNames
        tableView.reloadData()
    }

    /// The header's menu for a column position (nil for the gutter or empty space).
    func headerMenu(forPosition position: Int?) -> NSMenu {
        let menu = NSMenu()
        if let position, let column = modelColumn(atPosition: position) {
            let hide = NSMenuItem(
                title: "Hide “\(model.columns[column].name)”", action: #selector(hideColumn(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = column
            hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
            menu.addItem(hide)
            let fit = NSMenuItem(title: "Size to Fit", action: #selector(autosize(_:)), keyEquivalent: "")
            fit.target = self
            fit.representedObject = column
            menu.addItem(fit)
        }
        if !hiddenColumns.isEmpty {
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            let show = NSMenuItem(
                title: "Show All Columns (\(hiddenColumns.count) hidden)", action: #selector(showAllColumns(_:)),
                keyEquivalent: ""
            )
            show.target = self
            show.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            menu.addItem(show)
        }
        return menu
    }

    @objc private func hideColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        delegate?.gridDidRequestHideColumn(column)
    }

    @objc private func showAllColumns(_ sender: NSMenuItem) {
        delegate?.gridDidRequestShowAllColumns()
    }

    /// A first guess at column width from the type, so a table of integers is not as wide
    /// as one of text.
    static func defaultWidth(for meta: ColumnMeta) -> CGFloat {
        let byKind: CGFloat =
            switch meta.kind {
            case .bool: 70
            case .int, .uint: 90
            case .double, .decimal: 110
            case .date: 100
            case .time: 110
            case .timestamp: 190
            case .uuid: 260
            case .bytes: 110
            default: DesignTokens.Metrics.defaultColumnWidth
            }
        // A long column name still needs to be readable.
        return max(byKind, CGFloat(meta.name.count) * 8 + 24)
    }

    /// Sizes a column to the widest value among the loaded rows (SPEC §12.1).
    func autosizeColumn(named name: String) {
        guard let tableView, let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == name }),
            let columnIndex = model.columns.firstIndex(where: { $0.name == name })
        else { return }
        let font = DesignTokens.Fonts.grid
        var widest = (name as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11)]).width
        let sampleRange = visibleRowRange()
        for row in sampleRange {
            guard let value = model.value(row: row, column: columnIndex) else { continue }
            let text = GridCellView.displayText(for: value)
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        column.width = min(max(widest + 20, column.minWidth), column.maxWidth)
        reportColumnWidths()
    }

    func reportColumnWidths() {
        guard let tableView else { return }
        let widths = Dictionary(
            uniqueKeysWithValues: tableView.tableColumns
                .filter { $0.identifier != Self.rowNumberColumnID }
                .map { ($0.identifier.rawValue, Double($0.width)) })
        delegate?.gridDidChangeColumnWidths(widths)
    }

    // MARK: - Data source

    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.displayRowCount
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }

        if tableColumn.identifier == Self.rowNumberColumnID {
            let view =
                tableView.makeView(withIdentifier: GridRowNumberView.reuseIdentifier, owner: self)
                as? GridRowNumberView
                ?? {
                    let fresh = GridRowNumberView()
                    fresh.identifier = GridRowNumberView.reuseIdentifier
                    return fresh
                }()
            view.configure(row: row, isSelected: selection.containsRow(row))
            return view
        }

        guard
            let columnIndex = model.columns.firstIndex(where: {
                $0.name == tableColumn.identifier.rawValue
            })
        else { return nil }

        let view =
            tableView.makeView(withIdentifier: GridCellView.reuseIdentifier, owner: self) as? GridCellView
            ?? {
                let fresh = GridCellView()
                fresh.identifier = GridCellView.reuseIdentifier
                return fresh
            }()

        // Only a cell selection has a focused cell. Drawing the ring during a whole-row
        // selection puts a box around one arbitrary value inside the highlighted row.
        let isFocused =
            selection.mode == .cells
            && selection.focusRow == row
            && selection.focusColumn == columnIndex
        view.configure(
            value: model.value(row: row, column: columnIndex),
            changeState: model.changeState(row: row, column: columnIndex),
            isSelected: selection.contains(row: row, column: columnIndex, columnCount: model.columns.count),
            isFocused: isFocused,
            alignment: model.columns[columnIndex].kind.cellAlignment
        )
        return view
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false  // selection is drawn by the cells, from the grid's own model
    }

    /// The gutter stays at the left edge; nothing reorders it and nothing moves in front
    /// of it, because it is the grid's row control rather than one of its columns.
    public func tableView(
        _ tableView: NSTableView,
        shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        guard tableView.tableColumns.indices.contains(columnIndex) else { return false }
        if tableView.tableColumns[columnIndex].identifier == Self.rowNumberColumnID { return false }
        return newColumnIndex > 0
    }

    public func tableViewColumnDidResize(_ notification: Notification) {
        reportColumnWidths()
    }

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != Self.rowNumberColumnID,
            let column = model.columns.firstIndex(where: {
                $0.name == tableColumn.identifier.rawValue
            })
        else { return }
        let additive = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        delegate?.gridDidClickColumnHeader(column: column, additive: additive)
    }

    /// Puts the ascending/descending arrow on the columns the sort is on.
    func updateSortIndicators() {
        guard let tableView else { return }
        for column in tableView.tableColumns {
            let term = model.sort.first { $0.column == column.identifier.rawValue }
            tableView.setIndicatorImage(
                term.map { NSImage(named: $0.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") }
                    ?? nil,
                in: column
            )
        }
    }

    // MARK: - Lazy loading

    func observeScrolling() {
        guard let clipView = scrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestVisibleRows()
            }
        }
    }

    func visibleRowRange() -> Range<Int> {
        guard let tableView, let scrollView else { return 0 ..< 0 }
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0 else { return 0 ..< 0 }
        return visible.location ..< (visible.location + visible.length)
    }

    /// Asks for the rows around the viewport, with a little margin so scrolling does not
    /// stutter at the edge of what is loaded.
    func requestVisibleRows() {
        let visible = visibleRowRange()
        guard !visible.isEmpty else { return }
        let margin = 200
        let lower = max(0, visible.lowerBound - margin)
        let upper = min(model.displayRowCount, visible.upperBound + margin)
        guard lower < upper else { return }
        delegate?.gridDidRequestLoad(range: lower ..< upper)
    }

    /// Redraws only what is on screen, which is what an edit or a selection change needs.
    func redrawVisibleCells() {
        guard let tableView else { return }
        let rows = visibleRowRange()
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: rows),
            columnIndexes: IndexSet(integersIn: 0 ..< max(1, tableView.tableColumns.count))
        )
    }

    // MARK: - Selection

    func setSelection(_ new: GridSelection) {
        selection = new
        selectionBinding?.wrappedValue = new
        delegate?.gridDidChangeSelection(new)
        redrawVisibleCells()
        scrollToFocus()
    }

    func scrollToFocus() {
        guard let tableView, model.displayRowCount > 0 else { return }
        let row = min(max(0, selection.focusRow), model.displayRowCount - 1)
        tableView.scrollRowToVisible(row)
        if let position = position(ofModelColumn: selection.focusColumn) {
            tableView.scrollColumnToVisible(position)
        }
    }

    /// Selects a whole row; shift extends the span, command adds or removes single rows,
    /// the way a Finder list or a spreadsheet behaves.
    func handleRowClick(row: Int, extending: Bool, toggling: Bool = false) {
        var new = selection
        if toggling, new.mode == .rows {
            new.toggleRow(row)
        } else if extending, new.mode == .rows {
            new.focusRow = row
        } else {
            new = GridSelection(row: row, column: 0, mode: .rows)
        }
        new.focusColumn = max(0, model.columns.count - 1)
        new.anchorColumn = 0
        setSelection(new)
    }

    /// Extends the selection to the row under a drag that began in the gutter.
    func handleRowDrag(to row: Int) {
        guard selection.mode == .rows, selection.focusRow != row else { return }
        var new = selection
        new.focusRow = row
        setSelection(new)
    }

    /// Extends a cell selection to the cell under a drag.
    func handleCellDrag(to row: Int, column: Int) {
        guard selection.mode == .cells, selection.focusRow != row || selection.focusColumn != column else { return }
        var new = selection
        new.focusRow = row
        new.focusColumn = column
        setSelection(new)
    }

    func handleClick(row: Int, column: Int, extending: Bool) {
        var new = selection
        if extending {
            new.focusRow = row
            new.focusColumn = column
        } else {
            new = GridSelection(row: row, column: column)
        }
        setSelection(new)
    }

    @objc func handleDoubleClick() {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        beginEditingFocusedCell()
    }

    // MARK: - Editing

    func beginEditingFocusedCell() {
        guard model.isEditable, let tableView else { return }
        let row = selection.focusRow
        let column = selection.focusColumn
        guard model.columns.indices.contains(column), row < model.displayRowCount else { return }
        guard let position = position(ofModelColumn: column),
            let cell = tableView.view(atColumn: position, row: row, makeIfNecessary: false) as? GridCellView
        else { return }
        let current = model.value(row: row, column: column)
        let editor = GridInlineEditor(frame: cell.bounds)
        editor.stringValue =
            current.map { value in
                if case .null = value { return "" }
                return value.text ?? ""
            } ?? ""
        editor.onCommit = { [weak self] text in
            self?.delegate?.gridDidCommitEdit(row: row, column: column, text: text)
        }
        cell.addSubview(editor)
        editor.frame = cell.bounds
        editor.autoresizingMask = [.width, .height]
        tableView.window?.makeFirstResponder(editor)
    }

    /// How far to move to land on the next column that is shown, skipping hidden ones.
    func visibleStep(from column: Int, direction: Int) -> Int {
        var step = 1
        var probe = column + direction
        while model.columns.indices.contains(probe), hiddenColumns.contains(model.columns[probe].name) {
            step += 1
            probe += direction
        }
        return model.columns.indices.contains(probe) ? step : 0
    }

    // MARK: - Context menu

    /// The menu for a right-click on a cell: the value's own actions first, then the
    /// selection's, then the column's.
    func contextMenu(row: Int, column: Int?) -> NSMenu {
        let menu = NSMenu()
        if let column {
            if delegate?.gridHasReference(row: row, column: column) == true {
                let follow = NSMenuItem(
                    title: "Go to Referenced Row", action: #selector(followReference(_:)), keyEquivalent: "")
                follow.target = self
                follow.image = NSImage(systemSymbolName: Icon.goTo, accessibilityDescription: nil)
                follow.representedObject = [row, column]
                menu.addItem(follow)
                menu.addItem(.separator())
            }
            if model.isEditable, [.date, .time, .timestamp].contains(model.columns[column].kind) {
                let pick = NSMenuItem(
                    title: "Pick Date and Time…", action: #selector(showInspector(_:)), keyEquivalent: "")
                pick.target = self
                pick.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
                menu.addItem(pick)
            }
            let inspect = NSMenuItem(
                title: "Show in Inspector", action: #selector(showInspector(_:)), keyEquivalent: "")
            inspect.target = self
            inspect.image = NSImage(systemSymbolName: Icon.inspector, accessibilityDescription: nil)
            menu.addItem(inspect)
            let copyValue = NSMenuItem(title: "Copy Value", action: #selector(copyValue(_:)), keyEquivalent: "")
            copyValue.target = self
            copyValue.image = NSImage(systemSymbolName: Icon.copy, accessibilityDescription: nil)
            copyValue.representedObject = [row, column]
            menu.addItem(copyValue)
        }
        let copyAs = NSMenuItem(title: "Copy Selection As", action: nil, keyEquivalent: "")
        copyAs.image = NSImage(systemSymbolName: Icon.copy, accessibilityDescription: nil)
        let submenu = NSMenu()
        for format in ClipboardFormat.allCases {
            let item = NSMenuItem(title: format.displayName, action: #selector(copyAs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            submenu.addItem(item)
        }
        copyAs.submenu = submenu
        menu.addItem(copyAs)

        if model.isEditable {
            menu.addItem(.separator())
            let setNull = NSMenuItem(title: "Set NULL", action: #selector(setNull(_:)), keyEquivalent: "")
            setNull.target = self
            setNull.image = NSImage(systemSymbolName: Icon.null, accessibilityDescription: nil)
            menu.addItem(setNull)
            let addRow = NSMenuItem(title: "Add Row", action: #selector(addRow(_:)), keyEquivalent: "")
            addRow.target = self
            addRow.image = NSImage(systemSymbolName: Icon.add, accessibilityDescription: nil)
            menu.addItem(addRow)
            let count = selection.rows(totalRows: model.displayRowCount).count
            let delete = NSMenuItem(
                title: count > 1 ? "Delete \(count) Rows" : "Delete Row",
                action: #selector(deleteRows(_:)), keyEquivalent: ""
            )
            delete.target = self
            delete.image = NSImage(systemSymbolName: Icon.delete, accessibilityDescription: nil)
            menu.addItem(delete)
        }
        if let column {
            menu.addItem(.separator())
            let autosize = NSMenuItem(title: "Size Column to Fit", action: #selector(autosize(_:)), keyEquivalent: "")
            autosize.target = self
            autosize.representedObject = column
            menu.addItem(autosize)
        }
        return menu
    }

    @objc private func followReference(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        delegate?.gridDidRequestFollowReference(row: pair[0], column: pair[1])
    }

    @objc private func showInspector(_ sender: NSMenuItem) {
        delegate?.gridDidRequestInspector()
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2,
            let value = model.value(row: pair[0], column: pair[1])
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClipboardFormatter.cellText(value), forType: .string)
    }

    @objc private func copyAs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = ClipboardFormat(rawValue: raw) else { return }
        delegate?.gridDidRequestCopy(format: format)
    }

    @objc private func setNull(_ sender: NSMenuItem) { delegate?.gridDidRequestSetNull() }
    @objc private func addRow(_ sender: NSMenuItem) { delegate?.gridDidRequestAddRow() }
    @objc private func deleteRows(_ sender: NSMenuItem) { delegate?.gridDidRequestDeleteRows() }

    @objc private func autosize(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int, model.columns.indices.contains(column) else { return }
        autosizeColumn(named: model.columns[column].name)
    }

    // MARK: - Keyboard

    /// Handles the navigation and editing keys the grid owns. Returns false for anything
    /// the responder chain should keep handling.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let extending = event.modifierFlags.contains(.shift)
        let rowCount = model.displayRowCount
        let columnCount = model.columns.count
        guard rowCount > 0, columnCount > 0 else { return false }

        // ⌘A selects everything; the menu's Select All never reaches an NSTableView cell grid.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            var all = selection
            all.selectAll(rowCount: rowCount, columnCount: columnCount)
            setSelection(all)
            return true
        }

        var new = selection
        switch event.keyCode {
        case 126:
            new.move(rowDelta: -1, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 125:
            new.move(rowDelta: 1, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 123:
            new.move(
                rowDelta: 0, columnDelta: -visibleStep(from: selection.focusColumn, direction: -1), rowCount: rowCount,
                columnCount: columnCount, extending: extending)
        case 124:
            new.move(
                rowDelta: 0, columnDelta: visibleStep(from: selection.focusColumn, direction: 1), rowCount: rowCount,
                columnCount: columnCount, extending: extending)
        case 115:
            new.move(
                rowDelta: -rowCount, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 119:
            new.move(
                rowDelta: rowCount, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 116:
            new.move(rowDelta: -30, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 121:
            new.move(rowDelta: 30, columnDelta: 0, rowCount: rowCount, columnCount: columnCount, extending: extending)
        case 36:  // Return starts editing
            beginEditingFocusedCell()
            return true
        case 49:  // Space shows the focused cell in the inspector
            delegate?.gridDidRequestInspector()
            return true
        case 48:  // Tab moves right, wrapping to the next row
            if selection.focusColumn == columnCount - 1, selection.focusRow < rowCount - 1 {
                new.move(
                    rowDelta: 1, columnDelta: -(columnCount - 1), rowCount: rowCount, columnCount: columnCount,
                    extending: false)
            } else {
                new.move(rowDelta: 0, columnDelta: 1, rowCount: rowCount, columnCount: columnCount, extending: false)
            }
        default:
            return false
        }
        setSelection(new)
        return true
    }
}

/// The table view, which forwards the keys the grid owns to its coordinator.
public final class GridTableView: NSTableView {
    weak var controller: GridCoordinator?
    /// Where the current mouse drag began: in the row gutter, or on a cell.
    private var dragOrigin: DragOrigin?

    private enum DragOrigin { case gutter, cell }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if let controller, MainActor.assumeIsolated({ controller.handleKeyDown(event) }) { return }
        super.keyDown(with: event)
    }

    /// A right-click selects the cell under the pointer, then offers what can be done with it.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let position = column(at: point)
        guard row >= 0 else { return nil }
        var menu: NSMenu?
        MainActor.assumeIsolated {
            guard let controller else { return }
            let column = position >= 0 ? controller.modelColumn(atPosition: position) : nil
            if let column,
                !controller.selection.contains(row: row, column: column, columnCount: controller.model.columns.count)
            {
                controller.handleClick(row: row, column: column, extending: false)
            } else if column == nil, !controller.selection.containsRow(row) {
                controller.handleRowClick(row: row, extending: false)
            }
            menu = controller.contextMenu(row: row, column: column)
        }
        return menu
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let position = column(at: point)
        guard row >= 0, position >= 0 else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let extending = event.modifierFlags.contains(.shift)
        let toggling = event.modifierFlags.contains(.command)
        let isRowGutter = MainActor.assumeIsolated {
            controller?.modelColumn(atPosition: position) == nil
        }
        dragOrigin = isRowGutter ? .gutter : .cell
        MainActor.assumeIsolated {
            guard let controller else { return }
            if isRowGutter {
                controller.handleRowClick(row: row, extending: extending, toggling: toggling)
            } else if let column = controller.modelColumn(atPosition: position) {
                controller.handleClick(row: row, column: column, extending: extending)
            }
        }
        if isRowGutter { return }
        if event.clickCount == 2 {
            MainActor.assumeIsolated { controller?.beginEditingFocusedCell() }
        }
    }

    /// Dragging extends the selection: rows when it began in the gutter, cells otherwise.
    public override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let row = max(
            0,
            min(numberOfRows - 1, self.row(at: point) < 0 ? (point.y < 0 ? 0 : numberOfRows - 1) : self.row(at: point)))
        let position = column(at: point)
        MainActor.assumeIsolated {
            guard let controller else { return }
            switch dragOrigin {
            case .gutter:
                controller.handleRowDrag(to: row)
            case .cell:
                if position >= 0, let column = controller.modelColumn(atPosition: position) {
                    controller.handleCellDrag(to: row, column: column)
                }
            }
        }
        autoscroll(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        super.mouseUp(with: event)
    }
}

/// The text field shown while a cell is being edited.
final class GridInlineEditor: NSTextField {
    var onCommit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isSelectable = true
        isBordered = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        font = DesignTokens.Fonts.grid
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        finish(committing: true)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(committing: false)
    }

    private func finish(committing: Bool) {
        let text = stringValue
        let window = window
        removeFromSuperview()
        if committing { onCommit?(text) }
        window?.makeFirstResponder(window?.contentView)
    }
}

/// The header view, which offers Hide Column and Show All Columns on right-click.
final class GridHeaderView: NSTableHeaderView {
    weak var controller: GridCoordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let position = column(at: point)
        var menu: NSMenu?
        MainActor.assumeIsolated {
            menu = controller?.headerMenu(forPosition: position >= 0 ? position : nil)
        }
        return menu
    }
}
