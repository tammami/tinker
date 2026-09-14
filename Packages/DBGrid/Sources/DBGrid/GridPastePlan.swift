import DBCore
import Foundation

/// How text pasted into a table grid lands in its columns: cells copied from a
/// spreadsheet, a CSV, another grid's copy.
///
/// Whole records become new rows, each field in the column it belongs to. A record is a
/// line with as many fields as the table has columns, or any line under a first line
/// that names the columns — which is how rows without the auto-increment key come in.
/// Anything else is cells, written across from the focused column the way a spreadsheet
/// pastes: two cells copied to correct two values must never turn into a new row.
public struct GridPastePlan: Sendable, Hashable {
    /// The rows to write, the header left out.
    public let rows: [[String]]
    /// For each field position, the grid column it goes into; nil when there is none.
    public let columns: [Int?]
    /// True when the rows are records to add, false when they are cells to write over.
    public let appendsRows: Bool
    /// True when the first line named the columns and was not pasted as a row.
    public let hadHeader: Bool

    public init(rows: [[String]], columns: [Int?], appendsRows: Bool, hadHeader: Bool) {
        self.rows = rows
        self.columns = columns
        self.appendsRows = appendsRows
        self.hadHeader = hadHeader
    }

    /// The plan for `text` over a grid whose columns are `columns`, in grid order, or nil
    /// when there is nothing to paste.
    public static func make(text: String, columns: [ColumnInfo], focusColumn: Int) -> GridPastePlan? {
        guard !columns.isEmpty else { return nil }
        let names = columns.map { $0.name.lowercased() }
        // A spreadsheet and a grid copy put tabs on the clipboard, and Excel quotes a cell
        // that holds a tab, a line break or a quote: CSV's quoting with a tab between.
        if text.contains("\t") {
            let rows = CSVReader.parse(text, delimiter: "\t")
            guard !rows.isEmpty else { return nil }
            if let plan = records(rows, columnCount: columns.count, names: names) { return plan }
            return cells(rows, columnCount: columns.count, focusColumn: focusColumn)
        }
        // A comma or a semicolon is a CSV only when it makes records; inside one pasted
        // value — an address, a SET's labels — it is part of the value.
        for delimiter in [",", ";"] as [Character] where text.contains(delimiter) {
            let rows = CSVReader.parse(text, delimiter: delimiter)
            if let plan = records(rows, columnCount: columns.count, names: names) { return plan }
        }
        let lines = CSVReader.parse(text, delimiter: "\t")
        guard !lines.isEmpty else { return nil }
        return cells(lines, columnCount: columns.count, focusColumn: focusColumn)
    }

    /// Records, when the rows are: a header naming the columns, or every row exactly as
    /// wide as the table.
    private static func records(_ rows: [[String]], columnCount: Int, names: [String]) -> GridPastePlan? {
        guard let first = rows.first else { return nil }
        if let mapping = headerMapping(first, names: names) {
            return GridPastePlan(rows: Array(rows.dropFirst()), columns: mapping, appendsRows: true, hadHeader: true)
        }
        let width = first.count
        guard width > 1, width == columnCount, rows.allSatisfy({ $0.count == width }) else { return nil }
        return GridPastePlan(rows: rows, columns: Array(0 ..< columnCount), appendsRows: true, hadHeader: false)
    }

    /// Cells across from the focused column; a field past the last column has none.
    private static func cells(_ rows: [[String]], columnCount: Int, focusColumn: Int) -> GridPastePlan {
        let width = rows.map(\.count).max() ?? 0
        let mapping = (0 ..< width).map { offset -> Int? in
            let column = focusColumn + offset
            return column < columnCount ? column : nil
        }
        return GridPastePlan(rows: rows, columns: mapping, appendsRows: false, hadHeader: false)
    }

    /// The grid column each field of a first line names, when at least two fields name a
    /// column and none names something else; nil when the line is data.
    static func headerMapping(_ fields: [String], names: [String]) -> [Int?]? {
        var mapping: [Int?] = []
        var named = 0
        for field in fields {
            let name = field.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty {
                mapping.append(nil)
                continue
            }
            guard let index = names.firstIndex(of: name) else { return nil }
            mapping.append(index)
            named += 1
        }
        return named >= 2 ? mapping : nil
    }
}
