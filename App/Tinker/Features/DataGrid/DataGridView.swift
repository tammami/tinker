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
    /// Whether this column takes part in a foreign key, so its value can be picked from
    /// the referenced table rather than typed.
    func gridColumnReferences(_ column: Int) -> Bool
    /// A model that searches the referenced table for this cell, or nil when the column is
    /// not a foreign key. The grid hosts it in a popover over the cell.
    func gridReferencePicker(row: Int, column: Int) -> ReferencePickerModel?
    /// The referenced key the picker chose, keyed by referenced column name, is written
    /// back to the row's local columns.
    func gridDidPickReference(row: Int, column: Int, key: [String: DBValue])
    /// The fixed values an enum or SET column takes, so editing it picks rather than types.
    /// Nil for a column that takes free values or cannot be written.
    func gridChoices(_ column: Int) -> ColumnChoices?
    /// What a foreign-key cell's value points at ("Ada" for customer 1), shown beside it.
    /// A dictionary lookup: it is asked for every visible cell on every reload.
    func gridReferenceLabel(row: Int, column: Int) -> String?
    /// The context menu's copy, in the chosen format.
    func gridDidRequestCopy(format: ClipboardFormat)
    /// Edit › Paste (⌘V) with the grid first responder: the clipboard's rows and columns
    /// go into the grid.
    func gridDidRequestPaste()
    /// Whether a paste would land anywhere, for the menu item.
    func gridCanPaste() -> Bool
    func gridDidRequestSetNull()
    func gridDidRequestDeleteRows()
    func gridDidRequestAddRow()
    /// Edit › Undo and Redo, when the grid is first responder: one pending change at a time.
    func gridDidRequestUndo()
    func gridDidRequestRedo()
    func gridCanUndo() -> Bool
    func gridCanRedo() -> Bool
    func gridDidRequestAutosize(column: Int)
    /// The context menu's "Show on Map": this one row's geometry, from this column.
    func gridDidRequestShowOnMap(row: Int, column: Int)
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
    func gridColumnReferences(_ column: Int) -> Bool { false }
    func gridReferencePicker(row: Int, column: Int) -> ReferencePickerModel? { nil }
    func gridDidPickReference(row: Int, column: Int, key: [String: DBValue]) {}
    func gridChoices(_ column: Int) -> ColumnChoices? { nil }
    func gridDidRequestPaste() {}
    func gridCanPaste() -> Bool { false }
    func gridReferenceLabel(row: Int, column: Int) -> String? { nil }
    func gridDidRequestSetNull() {}
    func gridDidRequestDeleteRows() {}
    func gridDidRequestAddRow() {}
    func gridDidRequestAutosize(column: Int) {}
    func gridDidRequestShowOnMap(row: Int, column: Int) {}
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
        // SwiftUI keeps one table view for a pane and hands it another model when the
        // shown result changes (a Run All has several). The columns belong to the model
        // they were built for, so a swapped model is a full reload, revision or not.
        let modelChanged = coordinator.model !== model
        coordinator.model = model
        coordinator.delegate = delegate
        coordinator.selection = selection
        coordinator.selectionBinding = $selection
        coordinator.storedColumnWidths = columnWidths
        coordinator.hiddenColumns = hiddenColumns
        if coordinator.revision != revision || modelChanged {
            coordinator.revision = revision
            coordinator.renderedSelection = selection
            // A reload tears down the cell an inline editor sits in, which would end the
            // edit and commit half-typed text; it waits until the editor is done.
            if coordinator.inlineEditor != nil {
                coordinator.reloadWaitsForEditor = true
            } else {
                coordinator.reloadAfterRevision()
            }
        } else if coordinator.renderedSelection != selection {
            coordinator.renderedSelection = selection
            coordinator.redrawVisibleCells()
        }
        // Add Row moves the selection onto the new row from the controller's side, which
        // never goes through `setSelection`.
        coordinator.beginEditingIfInsertRow()
    }

    public func makeCoordinator() -> GridCoordinator {
        GridCoordinator(model: model, selection: selection, delegate: delegate)
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: GridCoordinator) {
        coordinator.stopObservingPeekRequests()
    }
}

/// Drives the table view: rows, cells, selection, keyboard and lazy loading.
@MainActor
public final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: GridModel
    var selection: GridSelection
    var selectionBinding: Binding<GridSelection>?
    weak var delegate: (any DataGridDelegate)?
    weak var tableView: GridTableView? {
        didSet { observePeekRequests() }
    }
    weak var scrollView: NSScrollView?
    var revision = -1
    /// The selection the visible cells were last drawn for. `updateNSView` runs on every
    /// SwiftUI render of the pane — a keystroke in the search field, a status change —
    /// and used to redraw every visible cell each time; now only a changed selection does.
    var renderedSelection: GridSelection?
    private var peekObserver: (any NSObjectProtocol)?

    /// The UI demo cannot right-click, so it asks for the map popover this way. The
    /// notification names the tab's controller, so only that tab's grid answers; hidden
    /// tabs keep their grids in the window and would otherwise answer too.
    private func observePeekRequests() {
        guard peekObserver == nil else { return }
        peekObserver = NotificationCenter.default.addObserver(
            forName: .tinkerPeekOnMap, object: nil, queue: .main
        ) { [weak self] note in
            // Read the cell out of the notification before hopping to the main actor.
            let row = note.userInfo?["row"] as? Int
            let column = note.userInfo?["column"] as? Int
            let target = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.tableView?.window, window.isKeyWindow, let row, let column,
                    let delegate = self.delegate, target == ObjectIdentifier(delegate as AnyObject)
                else { return }
                self.peekOnMap(row: row, column: column)
            }
        }
        pickObserver = NotificationCenter.default.addObserver(
            forName: .tinkerPresentReferencePicker, object: nil, queue: .main
        ) { [weak self] note in
            let row = note.userInfo?["row"] as? Int
            let column = note.userInfo?["column"] as? Int
            let demo = note.userInfo?["demo"] as? Bool ?? false
            let target = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.tableView?.window, demo || window.isKeyWindow, let row, let column,
                    let delegate = self.delegate, target == ObjectIdentifier(delegate as AnyObject)
                else { return }
                self.presentReferencePicker(row: row, column: column)
            }
        }
        temporalObserver = NotificationCenter.default.addObserver(
            forName: .tinkerPresentTemporalPicker, object: nil, queue: .main
        ) { [weak self] note in
            let row = note.userInfo?["row"] as? Int
            let column = note.userInfo?["column"] as? Int
            let demo = note.userInfo?["demo"] as? Bool ?? false
            let target = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.tableView?.window, demo || window.isKeyWindow, let row, let column,
                    let delegate = self.delegate, target == ObjectIdentifier(delegate as AnyObject)
                else { return }
                self.presentTemporalPicker(row: row, column: column)
            }
        }
        choiceObserver = NotificationCenter.default.addObserver(
            forName: .tinkerPresentChoices, object: nil, queue: .main
        ) { [weak self] note in
            let row = note.userInfo?["row"] as? Int
            let column = note.userInfo?["column"] as? Int
            let target = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let row, let column, let delegate = self.delegate,
                    target == ObjectIdentifier(delegate as AnyObject), let choices = delegate.gridChoices(column)
                else { return }
                self.presentChoices(choices, row: row, column: column)
            }
        }
    }
    private var pickObserver: (any NSObjectProtocol)?
    private var choiceObserver: (any NSObjectProtocol)?
    private var temporalObserver: (any NSObjectProtocol)?

    /// Removes the observer; the grid's view is going away.
    func stopObservingPeekRequests() {
        if let peekObserver { NotificationCenter.default.removeObserver(peekObserver) }
        peekObserver = nil
        if let pickObserver { NotificationCenter.default.removeObserver(pickObserver) }
        pickObserver = nil
        if let choiceObserver { NotificationCenter.default.removeObserver(choiceObserver) }
        choiceObserver = nil
        if let temporalObserver { NotificationCenter.default.removeObserver(temporalObserver) }
        temporalObserver = nil
        temporalPopover?.close()
        temporalPopover = nil
        choicesPopover?.close()
        choicesPopover = nil
        mapPopover?.close()
        mapPopover = nil
        referencePopover?.close()
        referencePopover = nil
    }
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
            alignment: model.columns[columnIndex].kind.cellAlignment,
            label: delegate?.gridReferenceLabel(row: row, column: columnIndex),
            columnName: model.columns[columnIndex].name
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
        beginEditingIfInsertRow()
    }

    /// A row the user is adding has nothing in it yet, so every cell it lands on opens for
    /// typing: no double-click, and Tab carries on to the next column. Only that row —
    /// browsing an existing one still opens an editor deliberately, with Return or a
    /// double-click.
    func beginEditingIfInsertRow() {
        guard selection.focusRow < model.displayRowCount,
            Self.opensForTyping(
                selection: selection, isEditable: model.isEditable, hasEditor: inlineEditor != nil,
                isPendingInsertRow: model.isPendingInsertRow(selection.focusRow))
        else { return }
        beginEditingFocusedCell()
    }

    /// The rule, apart from the table view so it can be tested: one cell of a row being
    /// added, on an editable grid, with nothing already open.
    static func opensForTyping(
        selection: GridSelection, isEditable: Bool, hasEditor: Bool, isPendingInsertRow: Bool
    ) -> Bool {
        guard isEditable, !hasEditor, isPendingInsertRow, selection.mode == .cells else { return false }
        return selection.anchorRow == selection.focusRow
            && selection.anchorColumn == selection.focusColumn
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

    /// The cell editor on screen, if any; a reload waits for it.
    weak var inlineEditor: GridInlineEditor?
    var reloadWaitsForEditor = false

    func reloadAfterRevision() {
        let columnsChanged = builtColumnNames != visibleColumnNames
        rebuildColumnsIfNeeded()
        updateGutterWidth()
        updateSortIndicators()
        guard let tableView else { return }
        // A full `reloadData` throws every row and cell view away and makes them again,
        // which for one screen of a wide result is most of a frame (measured in
        // `DataGridPerformanceTests`). A revision bump with the same columns — a page
        // arrived, a value was edited, a row was added — only needs the row count noted
        // and the cells on screen asked for their values again; those keep their views.
        if columnsChanged || tableView.numberOfRows == 0 {
            tableView.reloadData()
            return
        }
        tableView.noteNumberOfRowsChanged()
        // The rows on screen and the ones prepared just off it for responsive scrolling;
        // a row further away has no view and is asked for when it comes into view.
        let prepared = tableView.rows(in: tableView.preparedContentRect.union(tableView.visibleRect))
        guard prepared.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: prepared.location ..< prepared.location + prepared.length),
            columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns)
        )
    }

    /// Which editor a cell opens: the type decides, so an enum is picked from its values,
    /// a date or a timestamp gets a calendar, and everything else is typed (SPEC §12.2).
    enum InlineEditorKind: Equatable {
        case choices
        case temporal
        case text
    }

    /// The rule, apart from the table view so it can be tested.
    static func inlineEditorKind(for kind: DBValueKind, hasChoices: Bool) -> InlineEditorKind {
        if hasChoices { return .choices }
        return TemporalText.isTemporal(kind) ? .temporal : .text
    }

    func beginEditingFocusedCell() {
        guard model.isEditable, let tableView, inlineEditor == nil else { return }
        let row = selection.focusRow
        let column = selection.focusColumn
        guard model.columns.indices.contains(column), row < model.displayRowCount else { return }
        let choices = delegate?.gridChoices(column)
        switch Self.inlineEditorKind(for: model.columns[column].kind, hasChoices: choices != nil) {
        case .choices:
            // An enum or SET is picked, never typed.
            if let choices { presentChoices(choices, row: row, column: column) }
            return
        case .temporal:
            presentTemporalPicker(row: row, column: column)
            return
        case .text:
            break
        }
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
        editor.onFinish = { [weak self] movement in
            guard let self else { return }
            inlineEditor = nil
            if reloadWaitsForEditor {
                reloadWaitsForEditor = false
                reloadAfterRevision()
            }
            switch movement {
            case .tab: moveFocus(byColumns: 1)
            case .backtab: moveFocus(byColumns: -1)
            default: break
            }
        }
        inlineEditor = editor
        cell.addSubview(editor)
        editor.frame = cell.bounds
        editor.autoresizingMask = [.width, .height]
        tableView.window?.makeFirstResponder(editor)
    }

    /// Moves the focus one column after an edit ended with Tab, wrapping to the next row
    /// at the end of this one.
    func moveFocus(byColumns delta: Int) {
        let rowCount = model.displayRowCount
        let columnCount = model.columns.count
        guard rowCount > 0, columnCount > 0 else { return }
        var new = selection
        let step = visibleStep(from: selection.focusColumn, direction: delta > 0 ? 1 : -1)
        if step == 0 {
            let wrap = delta > 0 ? 1 : -1
            guard selection.focusRow + wrap >= 0, selection.focusRow + wrap < rowCount else { return }
            new.move(
                rowDelta: wrap, columnDelta: delta > 0 ? -(columnCount - 1) : (columnCount - 1),
                rowCount: rowCount, columnCount: columnCount, extending: false)
        } else {
            new.move(
                rowDelta: 0, columnDelta: delta > 0 ? step : -step, rowCount: rowCount,
                columnCount: columnCount, extending: false)
        }
        setSelection(new)
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
            }
            if model.isEditable, delegate?.gridColumnReferences(column) == true {
                let pick = NSMenuItem(
                    title: "Choose from Referenced Table…", action: #selector(pickReference(_:)), keyEquivalent: "")
                pick.target = self
                pick.image = NSImage(systemSymbolName: Icon.lookup, accessibilityDescription: nil)
                pick.representedObject = [row, column]
                menu.addItem(pick)
            }
            if delegate?.gridHasReference(row: row, column: column) == true
                || (model.isEditable && delegate?.gridColumnReferences(column) == true)
            {
                menu.addItem(.separator())
            }
            if model.isEditable, delegate?.gridChoices(column) != nil {
                let choose = NSMenuItem(title: "Choose Value…", action: #selector(chooseValue(_:)), keyEquivalent: "")
                choose.target = self
                choose.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
                choose.representedObject = [row, column]
                menu.addItem(choose)
            }
            if model.isEditable, TemporalText.isTemporal(model.columns[column].kind) {
                let isTime = model.columns[column].kind == .time
                let pick = NSMenuItem(
                    title: isTime ? "Pick Time…" : "Pick Date and Time…",
                    action: #selector(pickTemporal(_:)), keyEquivalent: "")
                pick.target = self
                pick.image = NSImage(systemSymbolName: isTime ? "clock" : "calendar", accessibilityDescription: nil)
                pick.representedObject = [row, column]
                menu.addItem(pick)
            }
            if GeometryColumns.detect(in: model, dialect: model.dialect).contains(column) {
                let show = NSMenuItem(title: "Show on Map", action: #selector(showOnMap(_:)), keyEquivalent: "")
                show.target = self
                show.image = NSImage(systemSymbolName: Icon.map, accessibilityDescription: nil)
                show.representedObject = [row, column]
                menu.addItem(show)
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

    @objc private func pickReference(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        presentReferencePicker(row: pair[0], column: pair[1])
    }

    /// Opens the foreign-key picker in a popover over the cell, so the grid stays put. The
    /// chosen key is written back through the delegate's ordinary edit path.
    func presentReferencePicker(row: Int, column: Int) {
        guard let tableView, let position = position(ofModelColumn: column),
            let model = delegate?.gridReferencePicker(row: row, column: column)
        else { return }
        let rect = tableView.frameOfCell(atColumn: position, row: row)
        let popover = NSPopover()
        popover.behavior = .transient
        // `popover` is captured weakly: the popover owns the hosting controller, which
        // owns this view, which owns these closures — a strong capture kept every picker
        // ever opened alive, together with its model and session reference.
        let view = ReferencePickerView(
            model: model,
            onChoose: { [weak self, weak popover] key in
                popover?.close()
                self?.delegate?.gridDidPickReference(row: row, column: column, key: key)
            },
            onSetNull: { [weak self, weak popover] in
                popover?.close()
                self?.delegate?.gridDidCommitEdit(row: row, column: column, text: "")
                self?.delegate?.gridDidRequestSetNull()
            },
            onCancel: { [weak popover] in popover?.close() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 360, height: 440)
        referencePopover = popover
        popover.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
    }

    private var referencePopover: NSPopover?

    @objc private func chooseValue(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2,
            let choices = delegate?.gridChoices(pair[1])
        else { return }
        presentChoices(choices, row: pair[0], column: pair[1])
    }

    /// Offers a column's fixed values over the cell: a menu for an enum, with the current
    /// value ticked, and checkboxes for a MySQL SET. What is picked goes through the
    /// delegate's ordinary edit path, so validation, auto-commit and the production gate apply.
    func presentChoices(_ choices: ColumnChoices, row: Int, column: Int) {
        guard let tableView, let position = position(ofModelColumn: column) else { return }
        // ⌥↓ or the inspector can ask for a cell scrolled out of sight; the menu belongs over it.
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(position)
        let rect = tableView.frameOfCell(atColumn: position, row: row)
        let current: String? = model.value(row: row, column: column).flatMap { $0.isNull ? nil : $0.text }
        if choices.allowsMany {
            let popover = NSPopover()
            popover.behavior = .transient
            let view = ChoiceField(choices: choices, text: current, isEditable: true) {
                [weak self, weak popover] text in
                popover?.close()
                self?.delegate?.gridDidCommitEdit(row: row, column: column, text: text)
            }
            .padding(DesignTokens.Spacing.md)
            .frame(width: 260)
            popover.contentViewController = NSHostingController(rootView: view)
            choicesPopover = popover
            popover.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var ticked: NSMenuItem?
        func add(_ title: String, text: String, isCurrent: Bool) {
            let item = NSMenuItem(title: title, action: #selector(pickChoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ChoicePick(row: row, column: column, text: text)
            if isCurrent {
                item.state = .on
                ticked = item
            }
            menu.addItem(item)
        }
        for label in choices.labels { add(label, text: label, isCurrent: label == current) }
        if choices.isNullable {
            menu.addItem(.separator())
            add("NULL", text: "", isCurrent: current == nil)
        }
        menu.popUp(positioning: ticked, at: NSPoint(x: rect.minX, y: rect.minY), in: tableView)
    }

    @objc private func pickChoice(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? ChoicePick else { return }
        delegate?.gridDidCommitEdit(row: pick.row, column: pick.column, text: pick.text)
    }

    private var choicesPopover: NSPopover?

    @objc private func pickTemporal(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        presentTemporalPicker(row: pair[0], column: pair[1])
    }

    /// Opens the calendar or clock over the cell, so a date is picked where it is read
    /// rather than in the inspector. What it writes goes through the delegate's ordinary
    /// edit path, so validation, auto-commit and the production gate apply.
    func presentTemporalPicker(row: Int, column: Int) {
        guard let tableView, model.columns.indices.contains(column),
            let position = position(ofModelColumn: column)
        else { return }
        // A row being added opens its cells as the focus lands on them, and every SwiftUI
        // update asks again; one picker at a time is enough.
        guard temporalPopover?.isShown != true else { return }
        // ⌥↓ or the inspector can ask for a cell scrolled out of sight; the picker belongs over it.
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(position)
        let rect = tableView.frameOfCell(atColumn: position, row: row)
        let meta = model.columns[column]
        let current = model.value(row: row, column: column)
        let text = current.map { $0.isNull ? "" : ($0.text ?? "") } ?? ""
        let popover = NSPopover()
        popover.behavior = .transient
        // Weakly captured, as the reference picker's closures are: the popover owns the
        // hosting controller, which owns this view, which owns these closures.
        let view = CellTemporalEditorView(
            kind: meta.kind, columnName: meta.name, text: text,
            onCommit: { [weak self, weak popover] picked in
                popover?.close()
                self?.delegate?.gridDidCommitEdit(row: row, column: column, text: picked)
                self?.takeFocusBack()
            },
            onCancel: { [weak self, weak popover] in
                popover?.close()
                self?.takeFocusBack()
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        temporalPopover = popover
        popover.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
    }

    private var temporalPopover: NSPopover?

    /// Returns the keyboard to the grid after a popover editor closes, so the arrow keys
    /// move the selection again rather than landing on a view that has gone.
    private func takeFocusBack() {
        guard let tableView else { return }
        tableView.window?.makeFirstResponder(tableView)
    }

    @objc private func showInspector(_ sender: NSMenuItem) {
        delegate?.gridDidRequestInspector()
    }

    /// "Show on Map": the row's geometry in a popover over its cell, so the grid stays
    /// where it is; the popover offers the full map pane for that row.
    @objc private func showOnMap(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        peekOnMap(row: pair[0], column: pair[1])
    }

    /// Opens the map popover over a cell. Also reached by the UI demo through
    /// `.tinkerPeekOnMap`, since nothing else can right-click for it.
    func peekOnMap(row: Int, column: Int) {
        guard let tableView, let position = position(ofModelColumn: column) else { return }
        let rect = tableView.frameOfCell(atColumn: position, row: row)
        let peek = MapPeekView(grid: model, row: row, column: column) { [weak self] in
            self?.mapPopover?.close()
            self?.delegate?.gridDidRequestShowOnMap(row: row, column: column)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: peek)
        popover.contentSize = NSSize(width: 480, height: 340)
        mapPopover = popover
        popover.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
    }

    private var mapPopover: NSPopover?

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

        // ⌥↓ opens the focused cell's picker: its enum values, or the referenced table.
        if event.modifierFlags.contains(.option), event.keyCode == 125, model.isEditable {
            if let choices = delegate?.gridChoices(selection.focusColumn) {
                presentChoices(choices, row: selection.focusRow, column: selection.focusColumn)
                return true
            }
            if delegate?.gridColumnReferences(selection.focusColumn) == true {
                presentReferencePicker(row: selection.focusRow, column: selection.focusColumn)
                return true
            }
            if model.columns.indices.contains(selection.focusColumn),
                TemporalText.isTemporal(model.columns[selection.focusColumn].kind)
            {
                presentTemporalPicker(row: selection.focusRow, column: selection.focusColumn)
                return true
            }
        }

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

    // Edit › Undo and Redo reach the first responder as `undo:`/`redo:`. The grid answers
    // them itself, from the model's own history, rather than through an `NSUndoManager`
    // whose registrations would have to mirror every edit path (SPEC §12.3).
    @objc public func undo(_ sender: Any?) {
        MainActor.assumeIsolated { controller?.delegate?.gridDidRequestUndo() }
    }

    @objc public func redo(_ sender: Any?) {
        MainActor.assumeIsolated { controller?.delegate?.gridDidRequestRedo() }
    }

    /// Edit › Paste (⌘V): rows copied from a spreadsheet, a CSV or another grid go in as
    /// cells or as new rows. A cell being edited has its own text field and paste.
    @objc public func paste(_ sender: Any?) {
        MainActor.assumeIsolated { controller?.delegate?.gridDidRequestPaste() }
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return MainActor.assumeIsolated { controller?.delegate?.gridCanUndo() ?? false }
        case #selector(redo(_:)): return MainActor.assumeIsolated { controller?.delegate?.gridCanRedo() ?? false }
        case #selector(paste(_:)): return MainActor.assumeIsolated { controller?.delegate?.gridCanPaste() ?? false }
        default: return super.validateUserInterfaceItem(item)
        }
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
    /// Called after the editor is gone, committed or not, with the key that ended it so
    /// the grid can carry on where Tab points.
    var onFinish: ((NSTextMovement) -> Void)?

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
        let raw = notification.userInfo?["NSTextMovement"] as? Int
        let movement = raw.flatMap(NSTextMovement.init(rawValue:)) ?? .other
        super.textDidEndEditing(notification)
        finish(committing: true, movement: movement)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(committing: false, movement: .cancel)
    }

    private func finish(committing: Bool, movement: NSTextMovement) {
        let text = stringValue
        let window = window
        removeFromSuperview()
        if committing { onCommit?(text) }
        // The table takes focus back before the grid moves on, or the move would land on a
        // view that is no longer in the responder chain.
        window?.makeFirstResponder(window?.contentView)
        onFinish?(movement)
    }
}

/// The header view: the right-click menu, and the column dividers as resize handles.
///
/// AppKit's own handle is a two-point band around a hairline, which is hard to hit and
/// gives nothing back when the pointer is on it. This header widens the band to
/// `resizeTolerance` either side, shows the divider under the pointer, and drags the
/// column itself so the width lands inside the column's own limits.
final class GridHeaderView: NSTableHeaderView {
    weak var controller: GridCoordinator?

    /// How far either side of a divider still counts as grabbing it.
    static let resizeTolerance: CGFloat = 6

    /// The divider the pointer is on, as an index into `resizeEdges()`; nil when it is
    /// not on one. Drawn thicker so the handle is visible before it is grabbed.
    private var hoveredEdge: Int?
    private var trackingArea: NSTrackingArea?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let position = column(at: point)
        var menu: NSMenu?
        MainActor.assumeIsolated {
            menu = controller?.headerMenu(forPosition: position >= 0 ? position : nil)
        }
        return menu
    }

    /// The divider nearest `x`, if `x` is within `tolerance` of one. Apart from the view
    /// so the hit rule can be tested.
    static func resizeBoundary(at x: CGFloat, edges: [CGFloat], tolerance: CGFloat) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (index, edge) in edges.enumerated() {
            // Two dividers can both be in range on a very narrow column; the nearer wins.
            let distance = abs(x - edge)
            guard distance <= tolerance, distance < bestDistance else { continue }
            best = index
            bestDistance = distance
        }
        return best
    }

    /// The trailing edge of every column that can be resized, in this view's coordinates.
    /// The gutter has no resizing mask, so its edge is not a handle.
    private func resizeEdges() -> [(x: CGFloat, column: NSTableColumn)] {
        guard let tableView else { return [] }
        return tableView.tableColumns.enumerated().compactMap { position, column in
            guard column.resizingMask.contains(.userResizingMask) else { return nil }
            return (headerRect(ofColumn: position).maxX, column)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        setHoveredEdge(Self.resizeBoundary(at: point.x, edges: resizeEdges().map(\.x), tolerance: Self.resizeTolerance))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredEdge(nil)
    }

    private func setHoveredEdge(_ edge: Int?) {
        guard hoveredEdge != edge else { return }
        hoveredEdge = edge
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let tolerance = Self.resizeTolerance
        for edge in resizeEdges() {
            addCursorRect(
                NSRect(x: edge.x - tolerance, y: 0, width: tolerance * 2, height: bounds.height),
                cursor: .resizeLeftRight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let edges = resizeEdges()
        guard let hoveredEdge, edges.indices.contains(hoveredEdge) else { return }
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: edges[hoveredEdge].x - 1, y: 2, width: 2, height: bounds.height - 4).fill()
    }

    // MARK: Dragging a divider

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges()
        guard let index = Self.resizeBoundary(at: point.x, edges: edges.map(\.x), tolerance: Self.resizeTolerance)
        else {
            super.mouseDown(with: event)
            return
        }
        let column = edges[index].column
        if event.clickCount == 2 {
            MainActor.assumeIsolated { controller?.autosizeColumn(named: column.identifier.rawValue) }
            window?.invalidateCursorRects(for: self)
            return
        }
        drag(columnID: column.identifier, from: point.x, startingAt: column.width)
    }

    /// Follows the pointer until the mouse goes up, setting the column's width as it goes.
    ///
    /// Setting the width posts `NSTableView.columnDidResizeNotification`, so the widths a
    /// table tab remembers are written by the path that already handles a resize. That
    /// notification is also why the column is looked up by identifier on every event
    /// rather than held: the tab publishes the new widths, SwiftUI updates the grid inside
    /// this loop, and a reload that rebuilds the columns would otherwise leave the drag
    /// pushing a column the table no longer shows.
    private func drag(columnID: NSUserInterfaceItemIdentifier, from startX: CGFloat, startingAt startWidth: CGFloat) {
        NSCursor.resizeLeftRight.set()
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) {
            event, stop in
            guard let event, let column = self.tableView?.tableColumns.first(where: { $0.identifier == columnID })
            else {
                stop.pointee = true
                return
            }
            let point = self.convert(event.locationInWindow, from: nil)
            let width = min(max(startWidth + point.x - startX, column.minWidth), column.maxWidth)
            if column.width != width { column.width = width }
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.setHoveredEdge(nil)
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }
}

/// The cell a value picked from an enum menu goes to.
private struct ChoicePick {
    let row: Int
    let column: Int
    let text: String
}

extension Notification.Name {
    /// Asks the grid to open a column's value picker over a cell (UI demo only).
    static let tinkerPresentChoices = Notification.Name("TinkerPresentChoices")
    /// Asks the visible grid to open its map popover over a cell (UI demo only).
    static let tinkerPeekOnMap = Notification.Name("TinkerPeekOnMap")
    /// The inspector asks the grid to open the foreign-key picker over a cell.
    static let tinkerPresentReferencePicker = Notification.Name("TinkerPresentReferencePicker")
    /// Asks the grid to open a date or time cell's picker over it (UI demo only).
    static let tinkerPresentTemporalPicker = Notification.Name("TinkerPresentTemporalPicker")
}
