import Charts
import DBCore
import DBGrid
import SwiftUI

/// A result drawn rather than listed.
///
/// The columns it offers are chosen, not guessed at: only a column that measures something
/// can be a value, and a key — `id`, `customer_id`, anything the server calls a primary
/// key — is offered as a label instead. Summing a key says nothing.
struct ChartPaneView: View {
    let grid: GridModel
    let revision: Int
    @Binding var kind: ChartKind
    @Binding var categoryColumn: Int
    @Binding var valueColumn: Int
    @Binding var aggregate: ChartAggregate

    @State private var highlighted: ChartPoint?
    @State private var cachedPlot = ChartPlot(points: [], rowsUsed: 0, rowsTotal: 0)

    private var columns: [ColumnMeta] { grid.columns }
    private var kinds: [ChartKind] { ChartSpec.kinds(columns: columns) }
    private var measures: [Int] { ChartSpec.measureColumns(columns) }
    private var categories: [Int] { ChartSpec.categoryColumns(columns) }

    /// Which column spaces the x axis by value: the other measure for a scatter, and the
    /// category itself for a line or an area when it is a number. Nil leaves x categorical.
    private var continuousX: Int? {
        if kind == .scatter { return measures.first { $0 != valueColumn } ?? measures.first }
        guard kind == .line || kind == .area, aggregate == .none,
            columns.indices.contains(categoryColumn), ChartSpec.isContinuous(columns[categoryColumn])
        else { return nil }
        return categoryColumn
    }

    /// Rebuilt only when something it depends on changes: hovering redraws the chart, and
    /// rereading every row on each mouse move would make a large result crawl.
    private var plot: ChartPlot {
        guard columns.indices.contains(valueColumn) else {
            return ChartPlot(points: [], rowsUsed: 0, rowsTotal: 0)
        }
        let labelIndex = columns.indices.contains(categoryColumn) ? categoryColumn : valueColumn
        let xIndex = continuousX
        return ChartSpec.plot(
            rowCount: grid.rowCount,
            aggregate: kind == .scatter ? .none : aggregate,
            labelOf: { row in grid.value(row: row, column: labelIndex)?.text ?? "—" },
            xOf: { row in xIndex.flatMap { ChartSpec.number(grid.value(row: row, column: $0)) } },
            valueOf: { row in ChartSpec.number(grid.value(row: row, column: valueColumn)) }
        )
    }

    private var points: [ChartPoint] { cachedPlot.points }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if kinds.isEmpty {
                EmptyStateView(
                    icon: Icon.chart,
                    title: "Nothing to chart",
                    message:
                        "This result has no column that measures anything. A key such as id is a number, but drawing it says nothing, so it is offered as a label instead."
                )
            } else if points.isEmpty {
                EmptyStateView(
                    icon: Icon.chart, title: "No values", message: "Every row's value is empty.")
            } else {
                chart
                    .padding(DesignTokens.Spacing.lg)
            }
        }
        .onAppear(perform: refresh)
        // A result switch resets the column bindings to -1 without touching the revision,
        // so the pane watches them too; re-picking makes them valid again and settles.
        .onChange(of: revision) { _, _ in refresh() }
        .onChange(of: valueColumn) { _, _ in refresh() }
        .onChange(of: categoryColumn) { _, _ in refresh() }
        .onChange(of: kind) { _, _ in refresh() }
        .onChange(of: aggregate) { _, _ in refresh() }
        .onChange(of: columns.map(\.name)) { _, _ in refresh() }
    }

    private func refresh() {
        chooseColumnsIfNeeded()
        cachedPlot = plot
        highlighted = nil
    }

    /// Opens on something sensible and stays out of the way afterwards: the first real
    /// measure, labelled by the first column that is not one.
    private func chooseColumnsIfNeeded() {
        if !measures.contains(valueColumn) { valueColumn = ChartSpec.defaultMeasure(columns) ?? -1 }
        if !categories.contains(categoryColumn) {
            categoryColumn = ChartSpec.defaultCategory(columns, measure: valueColumn) ?? -1
        }
        if !kinds.contains(kind) { kind = kinds.first ?? .bar }
    }

    @ViewBuilder
    private var controls: some View {
        PaneBar {
            BarPopUp(
                items: kinds.map { BarPopUp.Item(id: $0, title: $0.title, icon: $0.symbolName) },
                selection: $kind
            )
            .frame(width: 130)
            BarDivider()
            Text(kind == .scatter ? "y" : "Value").foregroundStyle(.secondary)
            BarPopUp(
                items: measures.map { BarPopUp.Item(id: $0, title: columns[$0].name) },
                selection: $valueColumn
            )
            .frame(width: 150)
            if kind == .scatter {
                Text("x").foregroundStyle(.secondary)
                Text(continuousX.map { columns[$0].name } ?? "—")
                    .foregroundStyle(.secondary)
            } else {
                BarDivider()
                Text("By").foregroundStyle(.secondary)
                BarPopUp(
                    items: categories.map { BarPopUp.Item(id: $0, title: columns[$0].name) },
                    selection: $categoryColumn
                )
                .frame(width: 150)
                BarPopUp(
                    items: ChartAggregate.allCases.map { BarPopUp.Item(id: $0, title: $0.title) },
                    selection: $aggregate
                )
                .frame(width: 120)
            }
            Spacer()
            if let highlighted {
                Text("\(highlighted.label): \(Self.reading(highlighted.value))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            } else if cachedPlot.isPartial {
                // A result pages, so the grid holds the rows around the reader rather than
                // all of them. Saying which were drawn is what stops a partial sum reading
                // as the total.
                Label(
                    "\(cachedPlot.rowsUsed) of \(cachedPlot.rowsTotal) rows",
                    systemImage: Icon.warning
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Scroll the Rows tab to load more, then come back.")
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .pie:
            Chart(points) { point in
                SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(by: .value("Label", point.label))
                    .opacity(highlighted == nil || highlighted == point ? 1 : 0.4)
            }
            .chartLegend(position: .trailing)
        case .scatter:
            Chart(points) { point in
                PointMark(
                    x: .value("x", point.x ?? Double(point.id)),
                    y: .value("y", point.value)
                )
                .opacity(highlighted == nil || highlighted == point ? 1 : 0.35)
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        case .bar:
            Chart(points) { point in
                BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    // "Each row" means each row: two rows sharing a label stand side by
                    // side rather than stacking into one bar that reads as their sum.
                    .position(by: .value("Row", aggregate == .none ? point.id : 0))
                    .opacity(highlighted == nil || highlighted == point ? 1 : 0.4)
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        case .line where points.allSatisfy({ $0.x != nil }) && continuousX != nil:
            Chart(points) { point in
                LineMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                PointMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                    .symbolSize(highlighted == point ? 90 : 25)
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        case .area where points.allSatisfy({ $0.x != nil }) && continuousX != nil:
            Chart(points) { point in
                AreaMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value)).opacity(0.6)
                LineMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
                PointMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .symbolSize(highlighted == point ? 90 : 25)
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        case .area:
            Chart(points) { point in
                AreaMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .opacity(0.6)
                LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
            }
            .chartOverlay { proxy in hoverOverlay(proxy) }
        }
    }

    /// Hovering reads out the point under the pointer. A chart nobody can interrogate is a
    /// picture, not a view of the data.
    private func hoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case let .active(location) = phase, let plot = proxy.plotFrame else {
                        highlighted = nil
                        return
                    }
                    let x = location.x - geometry[plot].origin.x
                    if continuousX != nil, let value: Double = proxy.value(atX: x) {
                        highlighted = points.min {
                            abs(($0.x ?? 0) - value) < abs(($1.x ?? 0) - value)
                        }
                    } else if let label: String = proxy.value(atX: x) {
                        highlighted = points.first { $0.label == label }
                    } else {
                        highlighted = nil
                    }
                }
        }
    }

    /// Enough digits to read, not so many that a bar's label wraps.
    static func reading(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.4g", value)
    }
}
