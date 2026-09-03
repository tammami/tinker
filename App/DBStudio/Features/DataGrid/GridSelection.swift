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

    public var isSingleCell: Bool {
        mode == .cells && rowRange.count == 1 && columnRange.count == 1
    }

    public func contains(row: Int, column: Int, columnCount: Int) -> Bool {
        switch mode {
        case .cells: rowRange.contains(row) && columnRange.contains(column)
        case .rows: rowRange.contains(row)
        case .columns: columnRange.contains(column)
        }
    }

    public func containsRow(_ row: Int) -> Bool {
        mode == .columns ? true : rowRange.contains(row)
    }

    /// The columns the selection covers, clamped to what exists.
    public func columns(totalColumns: Int) -> [Int] {
        switch mode {
        case .rows: Array(0 ..< totalColumns)
        case .cells, .columns: Array(columnRange.clamped(to: 0 ... max(0, totalColumns - 1)))
        }
    }

    /// The rows the selection covers, clamped to what exists.
    public func rows(totalRows: Int) -> [Int] {
        guard totalRows > 0 else { return [] }
        return switch mode {
        case .columns: Array(0 ..< totalRows)
        case .cells, .rows: Array(rowRange.clamped(to: 0 ... (totalRows - 1)))
        }
    }

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
        }
    }

    public mutating func selectAll(rowCount: Int, columnCount: Int) {
        mode = .cells
        anchorRow = 0
        anchorColumn = 0
        focusRow = max(0, rowCount - 1)
        focusColumn = max(0, columnCount - 1)
    }
}
