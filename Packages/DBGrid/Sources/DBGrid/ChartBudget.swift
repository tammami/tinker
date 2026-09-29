import DBCore
import Foundation

/// How many marks each shape may draw.
///
/// A chart is read, not scrolled: past a few dozen bars nobody can name one, and past a
/// thousand points a line is the same line. Drawing is also where the time goes — a mark
/// is laid out, styled and hit-tested — so the budget is on marks, never on rows read.
public struct ChartBudget: Sendable, Hashable {
    /// Bars drawn before the rest are folded into "Other".
    public var categories: Int

    /// What the pane's "Top" pop-up offers.
    public static let categoryChoices = [20, 50, 100]
    public static let defaultCategories = 50
    /// Slices of a pie before "Other": as many as the palette has hues to tell apart.
    public static let slices = 8
    /// Points of a line or an area.
    public static let linePoints = 1_000
    /// Points of a scatter.
    public static let scatterPoints = 2_000
    /// A line marks each point with a dot only while there are few enough to see.
    public static let dottedLinePoints = 200
    /// Labels along a categorical axis before they are thinned.
    public static let axisLabels = 24

    public init(categories: Int = ChartBudget.defaultCategories) {
        self.categories = max(1, categories)
    }
}

extension ChartSpec {
    // MARK: - Fitting a plot to its budget

    /// `plot` with no more points than `kind` may draw.
    ///
    /// - Bar: the largest `budget.categories`, largest first. The rest become one
    ///   "Other" bar when adding them up means something (sum, count); an average of
    ///   averages or a heap of unrelated rows does not, so those are left out and the
    ///   reduction says so.
    /// - Pie: values that are not positive cannot be an angle and are left out; then
    ///   the largest ``ChartBudget/slices`` and "Other".
    /// - Line, area: thinned keeping each stretch's highest and lowest point, in order.
    /// - Scatter: every n-th point, the same ones every time.
    ///
    /// A plot already within its budget comes back as it was, in its own order.
    public static func fit(
        _ plot: ChartPlot, kind: ChartKind, aggregate: ChartAggregate, budget: ChartBudget = ChartBudget()
    ) -> ChartPlot {
        switch kind {
        case .bar:
            let canMerge = aggregate == .sum || aggregate == .count
            return ranked(plot, points: plot.points, limit: budget.categories, merges: canMerge, excluded: 0)
        case .pie:
            let drawable = plot.points.filter { $0.value > 0 }
            // Slices are parts of a whole, so the rows of "each row" add up too.
            let canMerge = aggregate != .average
            return ranked(
                plot, points: drawable, limit: ChartBudget.slices, merges: canMerge,
                excluded: plot.points.count - drawable.count)
        case .line, .area:
            let thinned = downsample(plot.points, to: ChartBudget.linePoints)
            return replacing(
                plot, points: thinned,
                reduction: thinned.count < plot.points.count
                    ? .downsampled(shown: thinned.count, of: plot.points.count) : nil)
        case .scatter:
            let sampled = sample(plot.points, to: ChartBudget.scatterPoints)
            return replacing(
                plot, points: sampled,
                reduction: sampled.count < plot.points.count
                    ? .sampled(shown: sampled.count, of: plot.points.count) : nil)
        }
    }

    private static func replacing(
        _ plot: ChartPlot, points: [ChartPoint], reduction: ChartReduction?, excluded: Int = 0
    ) -> ChartPlot {
        ChartPlot(
            points: points, rowsUsed: plot.rowsUsed, rowsTotal: plot.rowsTotal, rowsRead: plot.rowsRead,
            reduction: reduction, excluded: excluded)
    }

    private static func ranked(
        _ plot: ChartPlot, points: [ChartPoint], limit: Int, merges: Bool, excluded: Int
    ) -> ChartPlot {
        guard points.count > limit else {
            return replacing(plot, points: points, reduction: nil, excluded: excluded)
        }
        // Ties keep the order the rows came in, so the same result draws the same bars.
        let sorted = points.sorted { $0.value != $1.value ? $0.value > $1.value : $0.id < $1.id }
        var kept = Array(sorted.prefix(limit))
        let rest = sorted.dropFirst(limit)
        if merges {
            let nextID = (points.map(\.id).max() ?? 0) + 1
            kept.append(
                ChartPoint(
                    id: nextID, label: otherLabel(rest.count), x: nil,
                    value: rest.reduce(0) { $0 + $1.value }, isOther: true))
        }
        return replacing(
            plot, points: kept,
            reduction: .top(shown: limit, of: points.count, merged: merges ? rest.count : 0),
            excluded: excluded)
    }

    /// The name of the point that stands for `count` categories past the budget.
    public static func otherLabel(_ count: Int) -> String { "Other (\(grouped(count)))" }

    /// At most `limit` points, in their order, holding the first, the last, and the
    /// lowest and highest of every stretch between — so the peaks and troughs a reader
    /// looks for are the ones that survive, the global ones among them.
    public static func downsample(_ points: [ChartPoint], to limit: Int) -> [ChartPoint] {
        guard limit >= 4, points.count > limit, let first = points.first, let last = points.last else {
            return points
        }
        let interior = points[1 ..< points.count - 1]
        let buckets = (limit - 2) / 2
        var result: [ChartPoint] = [first]
        result.reserveCapacity(limit)
        for bucket in 0 ..< buckets {
            let start = interior.startIndex + bucket * interior.count / buckets
            let end = interior.startIndex + (bucket + 1) * interior.count / buckets
            guard start < end else { continue }
            var low = start
            var high = start
            for index in start ..< end {
                if interior[index].value < interior[low].value { low = index }
                if interior[index].value > interior[high].value { high = index }
            }
            if low == high {
                result.append(interior[low])
            } else {
                result.append(interior[min(low, high)])
                result.append(interior[max(low, high)])
            }
        }
        result.append(last)
        return result
    }

    /// At most `limit` points taken at even steps: no randomness, so a chart drawn twice
    /// is the same chart.
    public static func sample(_ points: [ChartPoint], to limit: Int) -> [ChartPoint] {
        guard limit > 0, points.count > limit else { return points }
        return (0 ..< limit).map { points[$0 * points.count / limit] }
    }

    // MARK: - Opening on something sensible

    /// The aggregate a chart opens on when the reader has not chosen one: a sum where
    /// labels repeat — one bar per category is what was meant — and each row where every
    /// row has its own label.
    public static func suggestedAggregate(distinctLabels: Int, rows: Int) -> ChartAggregate {
        distinctLabels < rows ? .sum : .none
    }

    /// Columns that can name a point, the likeliest first: names and other text, then
    /// dates and the rest, then numbers, and keys last — a key names a row, but there is
    /// one per row, which is rarely what a chart groups by.
    public static func rankedCategoryColumns(_ columns: [ColumnMeta]) -> [Int] {
        func rank(_ column: ColumnMeta) -> Int {
            if isIdentifier(column) { return 3 }
            if column.kind == .string { return 0 }
            return column.kind.isNumeric ? 2 : 1
        }
        return categoryColumns(columns).sorted {
            let (left, right) = (rank(columns[$0]), rank(columns[$1]))
            return left != right ? left < right : $0 < $1
        }
    }

    // MARK: - Saying what was drawn

    /// The labels a categorical axis should print: all of them while they fit, and
    /// otherwise every n-th, so they never sit on top of each other.
    public static func axisLabels(_ points: [ChartPoint], limit: Int = ChartBudget.axisLabels) -> [String] {
        var seen = Set<String>()
        let labels = points.compactMap { seen.insert($0.label).inserted ? $0.label : nil }
        guard limit > 0, labels.count > limit else { return labels }
        let step = Int((Double(labels.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: labels.count, by: step).map { labels[$0] }
    }

    /// What the pane says beside the chart, or nil when the chart is the whole result:
    /// "Top 50 of 3,214 categories · 5,000 of 120,000 rows loaded".
    public static func caption(for plot: ChartPlot, aggregate: ChartAggregate) -> String? {
        var parts: [String] = []
        switch plot.reduction {
        case let .top(shown, of, merged):
            let noun = aggregate == .none ? "rows" : "categories"
            var text = "Top \(grouped(shown)) of \(grouped(of)) \(noun)"
            if merged == 0 { text += ", rest not drawn" }
            parts.append(text)
        case let .downsampled(shown, of):
            parts.append("\(grouped(shown)) of \(grouped(of)) points (downsampled)")
        case let .sampled(shown, of):
            parts.append("\(grouped(shown)) of \(grouped(of)) points (sampled)")
        case nil:
            break
        }
        if plot.excluded > 0 {
            parts.append("\(grouped(plot.excluded)) zero or negative left out")
        }
        if plot.isPartial {
            parts.append("\(grouped(plot.rowsRead)) of \(grouped(plot.rowsTotal)) rows loaded")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A count with its thousands apart, the same in every locale the app runs in.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var text = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) { text.append(",") }
            text.append(digit)
        }
        return number < 0 ? "-" + text : text
    }
}

// MARK: - Finding the point under the pointer

/// Finds a drawn point from where the pointer is, without walking the points: by
/// bisection along a numeric axis, by a table along a categorical one.
public struct ChartHitIndex: Sendable, Hashable {
    private let xs: [Double]
    private let positions: [Int]
    private let byLabel: [String: Int]

    public init(points: [ChartPoint]) {
        let placed = points.enumerated()
            .compactMap { offset, point in point.x.map { (x: $0, position: offset) } }
            .sorted { $0.x < $1.x }
        xs = placed.map(\.x)
        positions = placed.map(\.position)
        var table: [String: Int] = [:]
        table.reserveCapacity(points.count)
        for (offset, point) in points.enumerated() where table[point.label] == nil {
            table[point.label] = offset
        }
        byLabel = table
    }

    /// The index in `points` of the point whose x is nearest `x`, or nil with no x at all.
    public func nearest(toX x: Double) -> Int? {
        guard !xs.isEmpty else { return nil }
        var low = 0
        var high = xs.count
        while low < high {
            let middle = (low + high) / 2
            if xs[middle] < x { low = middle + 1 } else { high = middle }
        }
        if low == xs.count { return positions[low - 1] }
        if low > 0, abs(xs[low - 1] - x) <= abs(xs[low] - x) { return positions[low - 1] }
        return positions[low]
    }

    /// The index in `points` of the first point named `label`.
    public func position(ofLabel label: String) -> Int? { byLabel[label] }
}

// MARK: - Building a chart away from the window

/// The cells a chart reads, copied out of the grid: the measure, its label and, where
/// the axis is spaced by value, its x. Two or three columns of the rows that are
/// resident, never the rows themselves.
public struct ChartRows: Sendable {
    /// Each copied row's index in the result.
    public var rows: [Int] = []
    public var labels: [DBValue?] = []
    /// Empty when nothing spaces the axis by value.
    public var xs: [DBValue?] = []
    public var values: [DBValue?] = []
    /// Rows the result says it has.
    public var rowsTotal: Int

    public init(rowsTotal: Int) { self.rowsTotal = rowsTotal }

    public var count: Int { rows.count }

    public mutating func reserveCapacity(_ capacity: Int, withX: Bool) {
        rows.reserveCapacity(capacity)
        labels.reserveCapacity(capacity)
        values.reserveCapacity(capacity)
        if withX { xs.reserveCapacity(capacity) }
    }

    /// Adds one row's cells. `x` is kept only when `withX` says the axis is spaced by value.
    public mutating func append(row: Int, label: DBValue?, value: DBValue?, x: DBValue? = nil, withX: Bool = false) {
        rows.append(row)
        labels.append(label)
        values.append(value)
        if withX { xs.append(x) }
    }
}

/// What to draw from the rows.
public struct ChartRequest: Sendable, Hashable {
    public var kind: ChartKind
    /// Nil leaves the choice to ``ChartSpec/suggestedAggregate(distinctLabels:rows:)``.
    public var aggregate: ChartAggregate?
    public var budget: ChartBudget

    public init(kind: ChartKind, aggregate: ChartAggregate?, budget: ChartBudget = ChartBudget()) {
        self.kind = kind
        self.aggregate = aggregate
        self.budget = budget
    }
}

/// A chart ready to draw: the points within their budget, what finds them under the
/// pointer, and the choices that produced them.
public struct ChartDrawing: Sendable, Hashable, Identifiable {
    /// New for every drawing, so a view can tell two apart without comparing points.
    public let id: UUID
    public let plot: ChartPlot
    public let index: ChartHitIndex
    public let kind: ChartKind
    /// The aggregate used: the one asked for, or the one chosen when none was.
    public let aggregate: ChartAggregate
    /// True when the x axis is spaced by value rather than by position.
    public let isContinuous: Bool
    /// Categories (or rows, for "each row") before the budget was applied.
    public let categoriesTotal: Int
    /// What to say beside the chart; nil when the chart is the whole result.
    public let caption: String?

    public static func == (left: ChartDrawing, right: ChartDrawing) -> Bool { left.id == right.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Builds charts off the main actor, one at a time.
///
/// An actor rather than a detached task: the work leaves the window's thread because
/// the actor has its own executor, and a request that was overtaken is dropped at the
/// next stage rather than drawn.
public actor ChartPlotter {
    public init() {}

    /// The drawing for `rows`, or nil when the task was cancelled on the way.
    public func draw(_ rows: ChartRows, _ request: ChartRequest) -> ChartDrawing? {
        Self.draw(rows, request, isCancelled: { Task.isCancelled })
    }

    /// The same, callable from a test without a task.
    static func draw(
        _ rows: ChartRows, _ request: ChartRequest, isCancelled: () -> Bool = { false }
    )
        -> ChartDrawing?
    {
        let count = rows.count
        let hasX = rows.xs.count == count && count > 0
        // One pass and one table lookup a row: each label is given a slot the first time
        // it is seen, and the row's value is added to that slot's running total.
        var slots: [String: Int] = [:]
        var slotOfRow = [Int32](repeating: -1, count: count)
        var values = [Double](repeating: 0, count: count)
        var names: [String] = []
        var sums: [Double] = []
        var counts: [Int] = []
        var used = 0
        for index in 0 ..< count {
            if index & 0xFFF == 0, isCancelled() { return nil }
            guard let value = ChartSpec.number(rows.values[index]) else { continue }
            let label = rows.labels[index]?.text ?? "—"
            let slot: Int
            if let known = slots[label] {
                slot = known
            } else {
                slot = names.count
                slots[label] = slot
                names.append(label)
                sums.append(0)
                counts.append(0)
            }
            sums[slot] += value
            counts[slot] += 1
            values[index] = value
            slotOfRow[index] = Int32(truncatingIfNeeded: slot)
            used += 1
        }
        let aggregate: ChartAggregate =
            request.kind == .scatter
            ? .none : request.aggregate ?? ChartSpec.suggestedAggregate(distinctLabels: names.count, rows: used)
        let usesX = hasX && aggregate == .none
        if isCancelled() { return nil }

        var points: [ChartPoint] = []
        if aggregate == .none {
            points.reserveCapacity(used)
            for index in 0 ..< count where slotOfRow[index] >= 0 {
                // Each row is named by its place in the result, not in the copy.
                points.append(
                    ChartPoint(
                        id: rows.rows[index], label: names[Int(slotOfRow[index])],
                        x: usesX ? ChartSpec.number(rows.xs[index]) : nil, value: values[index]))
            }
        } else {
            points.reserveCapacity(names.count)
            for slot in names.indices {
                let value: Double =
                    switch aggregate {
                    case .average: sums[slot] / Double(max(counts[slot], 1))
                    case .count: Double(counts[slot])
                    case .sum, .none: sums[slot]
                    }
                points.append(ChartPoint(id: slot, label: names[slot], x: nil, value: value))
            }
        }
        if isCancelled() { return nil }
        let whole = ChartPlot(points: points, rowsUsed: used, rowsTotal: rows.rowsTotal, rowsRead: count)
        let fitted = ChartSpec.fit(whole, kind: request.kind, aggregate: aggregate, budget: request.budget)
        if isCancelled() { return nil }
        let isContinuous = usesX && !fitted.points.isEmpty && fitted.points.allSatisfy { $0.x != nil }
        return ChartDrawing(
            id: UUID(), plot: fitted, index: ChartHitIndex(points: fitted.points), kind: request.kind,
            aggregate: aggregate, isContinuous: isContinuous, categoriesTotal: points.count,
            caption: ChartSpec.caption(for: fitted, aggregate: aggregate))
    }
}
