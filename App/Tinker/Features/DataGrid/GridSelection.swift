import Foundation

/// Which cells are selected, in the shape a spreadsheet uses (SPEC §12.4).
///
/// A selection is a rectangle between an anchor and a focus, optionally extended to whole
/// rows or whole columns. Keeping it as two corners rather than a set of cells is what
/// lets a million-row column be selected without materialising anything.
public struct GridSelection: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case cells
        case rows
        case columns
    }

    public var mode: Mode = .cells
    /// Where the current drag or shift-extension started.
    public var anchorRow = 0
    public var anchorColumn = 0
    /// Where it currently ends. Keyboard navigation moves this.
    public var focusRow = 0
    public var focusColumn = 0
    /// Rows added with ⌘-click outside the anchor–focus span, in `.rows` mode.
    public var additionalRows: Set<Int> = []

    public init() {}

    public init(row: Int, column: Int, mode: Mode = .cells) {
        anchorRow = row
        focusRow = row
        anchorColumn = column
        focusColumn = column
        self.mode = mode
    }

    public var rowRange: ClosedRange<Int> {
        min(anchorRow, focusRow) ... max(anchorRow, focusRow)
    }

    public var columnRange: ClosedRange<Int> {
        min(anchorColumn, focusColumn) ... max(anchorColumn, focusColumn)
    }

    /// How many rows and columns the rectangle spans, for the status line.
    public var rowSpan: Int { rowRange.count }
    public var columnSpan: Int { columnRange.count }

    public var isSingleCell: Bool {
        mode == .cells && rowRange.count == 1 && columnRange.count == 1
    }

    public func contains(row: Int, column: Int, columnCount: Int) -> Bool {
        switch mode {
        case .cells: rowRange.contains(row) && columnRange.contains(column)
        case .rows: rowRange.contains(row) || additionalRows.contains(row)
        case .columns: columnRange.contains(column)
        }
    }

    public func containsRow(_ row: Int) -> Bool {
        switch mode {
        case .columns: true
        case .rows: rowRange.contains(row) || additionalRows.contains(row)
        case .cells: rowRange.contains(row)
        }
    }

    /// ⌘-click on a row: adds it when it is out, drops it when it is in. Dropping the
    /// anchor row hands the span over to the added rows so the selection survives.
    public mutating func toggleRow(_ row: Int) {
        if additionalRows.contains(row) {
            additionalRows.remove(row)
        } else if rowRange.contains(row) {
            // Break the span into the rows that remain, keeping the focus meaningful.
            let remaining = rowRange.filter { $0 != row }
            additionalRows.formUnion(remaining)
            if let first = remaining.first {
                anchorRow = first
                focusRow = first
                additionalRows.remove(first)
            }
        } else {
            additionalRows.insert(row)
        }
    }

    /// The columns the selection covers, clamped to what exists.
    public func columns(totalColumns: Int) -> [Int] {
        switch mode {
        case .rows: Array(0 ..< totalColumns)
        case .cells, .columns: Array(columnRange.clamped(to: 0 ... max(0, totalColumns - 1)))
        }
    }

    /// The rows the selection covers, clamped to what exists, in ascending order.
    public func rows(totalRows: Int) -> [Int] {
        guard totalRows > 0 else { return [] }
        switch mode {
        case .columns:
            return Array(0 ..< totalRows)
        case .cells:
            return Array(rowRange.clamped(to: 0 ... (totalRows - 1)))
        case .rows:
            var set = Set(rowRange.clamped(to: 0 ... (totalRows - 1)))
            set.formUnion(additionalRows.filter { $0 < totalRows })
            return set.sorted()
        }
    }

    /// How many rows are selected, counting the ⌘-clicked ones.
    public func selectedRowCount(totalRows: Int) -> Int { rows(totalRows: totalRows).count }

    /// Moves the focus, collapsing the selection unless `extending`.
    public mutating func move(
        rowDelta: Int,
        columnDelta: Int,
        rowCount: Int,
        columnCount: Int,
        extending: Bool
    ) {
        guard rowCount > 0, columnCount > 0 else { return }
        focusRow = min(max(0, focusRow + rowDelta), rowCount - 1)
        focusColumn = min(max(0, focusColumn + columnDelta), columnCount - 1)
        if !extending {
            anchorRow = focusRow
            anchorColumn = focusColumn
            mode = .cells
            additionalRows.removeAll()
        }
    }

    public mutating func selectAll(rowCount: Int, columnCount: Int) {
        mode = .cells
        additionalRows.removeAll()
        anchorRow = 0
        anchorColumn = 0
        focusRow = max(0, rowCount - 1)
        focusColumn = max(0, columnCount - 1)
    }
}
