import DBCore
import Foundation

/// The shapes a result can be drawn as.
public enum ChartKind: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case bar, line, area, pie, scatter

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var symbolName: String {
        switch self {
        case .bar: "chart.bar"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .pie: "chart.pie"
        case .scatter: "chart.dots.scatter"
        }
    }
}

/// How rows sharing a category are combined.
public enum ChartAggregate: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case none, sum, average, count

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Each row"
        case .sum: "Sum"
        case .average: "Average"
        case .count: "Count"
        }
    }
}

/// What was drawn, and out of how much.
///
/// A result pages: a grid holds the rows around where the reader is, not all of them. A
/// chart that quietly summed the resident page would present a fraction as the total, so
/// the count travels with the points and the pane says so when it is short.
public struct ChartPlot: Sendable, Hashable {
    public let points: [ChartPoint]
    /// Rows that gave a value.
    public let rowsUsed: Int
    /// Rows the result says it has.
    public let rowsTotal: Int

    public init(points: [ChartPoint], rowsUsed: Int, rowsTotal: Int) {
        self.points = points
        self.rowsUsed = rowsUsed
        self.rowsTotal = rowsTotal
    }

    /// True when what was drawn is not the whole result.
    public var isPartial: Bool { rowsUsed < rowsTotal }
}

/// One plotted point.
public struct ChartPoint: Sendable, Hashable, Identifiable {
    public let id: Int
    /// The x label, always present, so a bar or a pie has something to name a slice by.
    public let label: String
    /// The x value when it is a number or a date, for a line or a scatter that has to
    /// space its points by value rather than by position.
    public let x: Double?
    public let value: Double

    public init(id: Int, label: String, x: Double?, value: Double) {
        self.id = id
        self.label = label
        self.x = x
        self.value = value
    }
}

/// Decides what a result can be charted as, and turns its rows into points.
///
/// The rule that matters: **a key is not a measure**. `id` is a number and summing it or
/// drawing it as a bar is meaningless, so a column the server calls a primary key, or one
/// named like a key, is offered as a label and never as a value.
public enum ChartSpec {
    /// Rows beyond this are not plotted: past a few thousand marks a chart is a smear, and
    /// drawing them costs more than reading them.
    public static let pointLimit = 5_000

    /// True for a column that identifies a row rather than measuring anything.
    public static func isIdentifier(_ column: ColumnMeta) -> Bool {
        if column.isPrimaryKey == true { return true }
        if column.kind == .uuid { return true }
        // Exact names and the `_id` suffix only. A looser `hasSuffix("id")` would take
        // `paid`, `valid` and `solid` with it, and those are real numbers.
        let name = column.name.lowercased()
        if ["id", "rowid", "oid", "uuid", "guid"].contains(name) { return true }
        return name.hasSuffix("_id")
    }

    /// Columns whose values can be a height, a length or a slice.
    public static func measureColumns(_ columns: [ColumnMeta]) -> [Int] {
        columns.indices.filter { columns[$0].kind.isNumeric && !isIdentifier(columns[$0]) }
    }

    /// Columns that can name a point. Anything but bytes, which have no reading.
    public static func categoryColumns(_ columns: [ColumnMeta]) -> [Int] {
        columns.indices.filter { columns[$0].kind != .bytes }
    }

    /// True when a line or an area should space its points along x by value rather than by
    /// position. Numbers only: a date reads as a number too, but converting one costs its
    /// exactness, and a dated result is normally already in the order it should be drawn.
    public static func isContinuous(_ column: ColumnMeta) -> Bool { column.kind.isNumeric }

    /// The shapes this result supports. A pie needs one measure and something to name its
    /// slices; a scatter needs a second measure to put on x.
    public static func kinds(columns: [ColumnMeta]) -> [ChartKind] {
        let measures = measureColumns(columns)
        guard !measures.isEmpty else { return [] }
        var kinds: [ChartKind] = [.bar, .line, .area, .pie]
        if measures.count >= 2 { kinds.append(.scatter) }
        return kinds
    }

    /// The measure a result should open on: the first one that is not a key.
    public static func defaultMeasure(_ columns: [ColumnMeta]) -> Int? { measureColumns(columns).first }

    /// The label a result should open on: the first column that is not a measure — usually
    /// the name beside the numbers — and the key only if there is nothing else.
    public static func defaultCategory(_ columns: [ColumnMeta], measure: Int?) -> Int? {
        let candidates = categoryColumns(columns)
        if let text = candidates.first(where: { $0 != measure && !columns[$0].kind.isNumeric }) { return text }
        return candidates.first { $0 != measure } ?? candidates.first
    }

    /// A value as a number, or nil when it is not one. Decimals keep their digits until
    /// here; a plotted point is a `Double` and cannot, which is why exact values stay in
    /// the grid and only the drawing rounds.
    public static func number(_ value: DBValue?) -> Double? {
        switch value {
        case let .int(number): Double(number)
        case let .uint(number): Double(number)
        case let .double(number): number
        case let .decimal(text): finite(Double(text))
        case let .bool(flag): flag ? 1 : 0
        case let .string(text): finite(Double(text))
        default: nil
        }
    }

    /// PostgreSQL's `numeric` stores `NaN` and `double precision` stores `Infinity`, and
    /// Swift parses both. Neither can scale an axis, and a NaN never equals itself, so a
    /// point holding one could never be highlighted either.
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// The points for one measure, aggregated as asked, and how many rows produced them.
    ///
    /// `labelOf` and `valueOf` read one row so the caller keeps the rows; nothing here
    /// holds a grid. A row the caller cannot read — a page that is not resident — returns
    /// nil and is counted as missing rather than drawn as a zero.
    public static func plot(
        rowCount: Int,
        aggregate: ChartAggregate,
        labelOf: (Int) -> String,
        xOf: (Int) -> Double?,
        valueOf: (Int) -> Double?
    ) -> ChartPlot {
        let rows = min(rowCount, pointLimit)
        guard rows > 0 else { return ChartPlot(points: [], rowsUsed: 0, rowsTotal: rowCount) }
        guard aggregate != .none else {
            let points = (0 ..< rows).compactMap { row -> ChartPoint? in
                guard let value = valueOf(row) else { return nil }
                return ChartPoint(id: row, label: labelOf(row), x: xOf(row), value: value)
            }
            return ChartPlot(points: points, rowsUsed: points.count, rowsTotal: rowCount)
        }
        var order: [String] = []
        var used = 0
        var totals: [String: (sum: Double, count: Int, x: Double?)] = [:]
        for row in 0 ..< rows {
            let label = labelOf(row)
            let value = valueOf(row)
            if value == nil { continue }
            used += 1
            if totals[label] == nil {
                order.append(label)
                totals[label] = (0, 0, xOf(row))
            }
            totals[label]?.sum += value ?? 0
            totals[label]?.count += 1
        }
        let points = order.enumerated().compactMap { index, label -> ChartPoint? in
            guard let entry = totals[label] else { return nil }
            let value: Double =
                switch aggregate {
                case .sum: entry.sum
                case .average: entry.count == 0 ? 0 : entry.sum / Double(entry.count)
                case .count: Double(entry.count)
                case .none: entry.sum
                }
            return ChartPoint(id: index, label: label, x: entry.x, value: value)
        }
        return ChartPlot(points: points, rowsUsed: used, rowsTotal: rowCount)
    }
}
