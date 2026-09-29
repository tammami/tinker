import Charts
import DBCore
import DBGrid
import Observation
import SwiftUI

/// A result drawn rather than listed.
///
/// The columns it offers are chosen, not guessed at: only a column that measures something
/// can be a value, and a key — `id`, `customer_id`, anything the server calls a primary
/// key — is offered as a label instead. Summing a key says nothing.
///
/// The pane opens at once whatever the result holds. It never asks whether to go on: it
/// draws within a budget of marks (`ChartBudget`), builds the points away from the
/// window, and says beside the chart what it drew out of how much.
struct ChartPaneView: View {
    let grid: GridModel
    let revision: Int
    @Binding var kind: ChartKind
    @Binding var categoryColumn: Int
    @Binding var valueColumn: Int
    /// Nil until the reader chooses: the chart then picks what the labels call for.
    @Binding var aggregate: ChartAggregate?
    /// How many bars are drawn before the rest become "Other".
    @Binding var categoryLimit: Int

    /// What is on screen. It stays there while its successor is built, so changing a
    /// column never blanks the pane.
    @State private var drawing: ChartDrawing?
    @State private var isPreparing = false
    @State private var hover = ChartHover()

    /// One for the app: a chart overtaken by the next is dropped, not drawn.
    private static let plotter = ChartPlotter()
    /// A build shorter than this shows no progress; a flash of it would be noise.
    private static let progressDelay = Duration.milliseconds(150)
    /// Past this many columns a pop-up is a wall of names, so the picker can be searched.
    private static let searchableColumnCount = 30

    private var columns: [ColumnMeta] { grid.columns }
    private var kinds: [ChartKind] { ChartSpec.kinds(columns: columns) }
    private var measures: [Int] { ChartSpec.measureColumns(columns) }
    private var categories: [Int] { ChartSpec.rankedCategoryColumns(columns) }

    /// The aggregate the pop-up shows: the reader's, or the one the chart chose.
    private var shownAggregate: ChartAggregate { aggregate ?? drawing?.aggregate ?? .none }

    /// Which column spaces the x axis by value: the other measure for a scatter, and the
    /// category itself for a line or an area when it is a number. Nil leaves x categorical.
    private var continuousX: Int? {
        if kind == .scatter { return measures.first { $0 != valueColumn } ?? measures.first }
        guard kind == .line || kind == .area,
            columns.indices.contains(categoryColumn), ChartSpec.isContinuous(columns[categoryColumn])
        else { return nil }
        return categoryColumn
    }

    /// Everything a drawing depends on. When any of it changes the build in flight is
    /// cancelled and another starts; when the pane goes away the build goes with it.
    private struct Job: Hashable {
        let revision: Int
        let kind: ChartKind
        let valueColumn: Int
        let categoryColumn: Int
        let aggregate: ChartAggregate?
        let categoryLimit: Int
        let columnNames: [String]
    }

    private var job: Job {
        Job(
            revision: revision, kind: kind, valueColumn: valueColumn, categoryColumn: categoryColumn,
            aggregate: aggregate, categoryLimit: categoryLimit, columnNames: columns.map(\.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task(id: job) { await rebuild() }
    }

    @ViewBuilder
    private var content: some View {
        if kinds.isEmpty {
            EmptyStateView(
                icon: Icon.chart,
                title: "Nothing to chart",
                message:
                    "This result has no column that measures anything. A key such as id is a number, but drawing it says nothing, so it is offered as a label instead."
            )
        } else if let drawing {
            if drawing.plot.points.isEmpty {
                EmptyStateView(
                    icon: Icon.chart, title: "No values",
                    message: drawing.plot.excluded > 0
                        ? "A pie draws positive values only, and this column has none."
                        : "Every row's value is empty.")
            } else {
                ChartMarks(drawing: drawing, hover: hover)
                    .equatable()
                    .padding(DesignTokens.Spacing.lg)
                    .overlay(alignment: .top) { if isPreparing { preparing } }
            }
        } else {
            EmptyStateView(icon: Icon.chart, title: "Preparing chart…")
        }
    }

    private var preparing: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Preparing chart…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, DesignTokens.Spacing.sm)
    }

    // MARK: - Building

    private func rebuild() async {
        chooseColumnsIfNeeded()
        guard columns.indices.contains(valueColumn), kinds.contains(kind) else {
            drawing = nil
            return
        }
        let rows = snapshot()
        let request = ChartRequest(
            kind: kind, aggregate: kind == .scatter ? ChartAggregate.none : aggregate,
            budget: ChartBudget(categories: categoryLimit))
        // Inherits the main actor and this task's cancellation: it only flips a flag.
        let progress = Task {
            try? await Task.sleep(for: Self.progressDelay)
            if !Task.isCancelled { isPreparing = true }
        }
        let built = await Self.plotter.draw(rows, request)
        progress.cancel()
        isPreparing = false
        guard !Task.isCancelled, let built else { return }
        hover.point = nil
        drawing = built
    }

    /// Copies the two or three cells a chart reads from each resident row. The rows stay
    /// in the grid; what leaves the main actor is the copy.
    private func snapshot() -> ChartRows {
        let labelIndex = columns.indices.contains(categoryColumn) ? categoryColumn : valueColumn
        let xIndex = continuousX
        let total = grid.rowCount
        var rows = ChartRows(rowsTotal: total)

        func read(_ range: Range<Int>) {
            for row in range {
                guard rows.count < ChartSpec.rowLimit else { return }
                guard let value = grid.value(row: row, column: valueColumn) else { continue }
                rows.append(
                    row: row, label: grid.value(row: row, column: labelIndex), value: value,
                    x: xIndex.flatMap { grid.value(row: row, column: $0) }, withX: xIndex != nil)
            }
        }

        if total <= ChartSpec.rowLimit {
            rows.reserveCapacity(min(total, grid.buffer.count + 64), withX: xIndex != nil)
            read(0 ..< total)
        } else {
            // A result of millions holds a few pages; walk those rather than every index.
            let pageSize = grid.buffer.pageSize
            rows.reserveCapacity(min(grid.buffer.count, ChartSpec.rowLimit), withX: xIndex != nil)
            for page in grid.buffer.loadedPages.sorted() {
                read(page * pageSize ..< min((page + 1) * pageSize, total))
            }
        }
        return rows
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

    // MARK: - Controls

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
            columnPicker(measures, selection: $valueColumn, label: "value column")
            if kind == .scatter {
                Text("x").foregroundStyle(.secondary)
                Text(continuousX.map { columns[$0].name } ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                BarDivider()
                Text("By").foregroundStyle(.secondary)
                columnPicker(categories, selection: $categoryColumn, label: "category column")
                BarPopUp(
                    items: ChartAggregate.allCases.map { BarPopUp.Item(id: $0, title: $0.title) },
                    selection: Binding(get: { shownAggregate }, set: { aggregate = $0 })
                )
                .frame(width: 120)
                .accessibilityLabel("aggregate")
            }
            if showsCategoryLimit {
                BarPopUp(
                    items: ChartBudget.categoryChoices.map { BarPopUp.Item(id: $0, title: "Top \($0)") },
                    selection: $categoryLimit
                )
                .frame(width: 96)
                .help("How many bars are drawn; the rest are added up into Other when they can be")
                .accessibilityLabel("bars drawn")
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            ChartReadout(hover: hover, caption: drawing?.caption, isPartial: drawing?.plot.isPartial ?? false)
        }
    }

    /// Offered only where it changes something: a bar chart with more categories than
    /// the smallest choice draws.
    private var showsCategoryLimit: Bool {
        guard kind == .bar, let drawing, drawing.kind == .bar,
            let smallest = ChartBudget.categoryChoices.first
        else { return false }
        return drawing.categoriesTotal > smallest
    }

    @ViewBuilder
    private func columnPicker(_ choices: [Int], selection: Binding<Int>, label: String) -> some View {
        if choices.count > Self.searchableColumnCount {
            SearchableColumnPicker(
                choices: choices.map { (index: $0, name: columns[$0].name, type: columns[$0].nativeTypeName) },
                selection: selection
            )
            .frame(width: 150)
            .accessibilityLabel(label)
        } else {
            BarPopUp(
                items: choices.map { BarPopUp.Item(id: $0, title: columns[$0].name) },
                selection: selection
            )
            .frame(width: 150)
            .accessibilityLabel(label)
        }
    }

    /// Enough digits to read, not so many that a bar's label wraps.
    static func reading(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.4g", value)
    }
}

// MARK: - Hover

/// The point under the pointer. It lives outside the pane's own state so that moving the
/// mouse redraws the readout and the marker — two small views — and never the marks.
@MainActor
@Observable
final class ChartHover {
    var point: ChartPoint?
}

/// What the bar says at its trailing edge: the point under the pointer, or else what
/// the chart drew out of how much.
private struct ChartReadout: View {
    let hover: ChartHover
    let caption: String?
    let isPartial: Bool

    var body: some View {
        if let point = hover.point {
            Text("\(point.label): \(ChartPaneView.reading(point.value))")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let caption {
            // Saying which rows were drawn is what stops a partial sum reading as the total.
            Label(caption, systemImage: Icon.info)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    isPartial
                        ? "\(caption). The chart reads the rows the grid has loaded; scroll the Rows tab to load more."
                        : caption)
        }
    }
}

// MARK: - Marks

/// The chart itself. Equal to itself for as long as the drawing is the same one, so
/// nothing but a new drawing lays the marks out again.
private struct ChartMarks: View, Equatable {
    let drawing: ChartDrawing
    let hover: ChartHover

    nonisolated static func == (left: ChartMarks, right: ChartMarks) -> Bool {
        left.drawing.id == right.drawing.id
    }

    private var points: [ChartPoint] { drawing.plot.points }
    private var palette: [NSColor] { DesignTokens.Colors.chartCategories }

    /// The single hue a line, an area or a scatter draws in. One series is one colour:
    /// changing it from point to point would claim a difference the data does not have.
    private var seriesColour: Color { Color(nsColor: palette[0]) }

    /// The categories in the order the plot lists them, which is the order the hues are
    /// handed out in.
    private var categoryOrder: [String] {
        var seen = Set<String>()
        return points.compactMap { seen.insert($0.label).inserted ? $0.label : nil }
    }

    /// A hue a category while there are hues to tell apart; past the palette every bar
    /// shares one, and "Other" is always grey: it is not a category.
    private func colours(for order: [String]) -> [Color] {
        let distinct = order.count <= palette.count
        let other = points.first(where: \.isOther)?.label
        return order.enumerated().map { index, label in
            if label == other { return Color(nsColor: .tertiaryLabelColor) }
            return Color(nsColor: distinct ? palette[index] : palette[0])
        }
    }

    /// A dot a point only while the dots can be told apart.
    private var showsDots: Bool { points.count <= ChartBudget.dottedLinePoints }

    var body: some View {
        switch drawing.kind {
        case .pie:
            let order = categoryOrder
            Chart(points) { point in
                SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(by: .value("Label", point.label))
            }
            .chartForegroundStyleScale(domain: order, range: colours(for: order))
            .chartLegend(position: .trailing)
        case .scatter:
            Chart(points) { point in
                PointMark(x: .value("x", point.x ?? Double(point.id)), y: .value("y", point.value))
                    .foregroundStyle(seriesColour)
                    .opacity(points.count > ChartBudget.dottedLinePoints ? 0.55 : 1)
            }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: true) }
        case .bar:
            let order = categoryOrder
            Chart(points) { point in
                BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    // "Each row" means each row: two rows sharing a label stand side by
                    // side rather than stacking into one bar that reads as their sum.
                    .position(by: .value("Row", drawing.aggregate == .none ? point.id : 0))
                    .foregroundStyle(by: .value("Label", point.label))
            }
            .chartForegroundStyleScale(domain: order, range: colours(for: order))
            // No legend: the x axis already names every bar, and a legend repeating it
            // would take the room the bars are drawn in.
            .chartLegend(.hidden)
            .chartXAxis { categoryAxis }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: false) }
        case .line where drawing.isContinuous:
            Chart(points) { point in
                LineMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
                if showsDots {
                    PointMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                        .foregroundStyle(seriesColour)
                        .symbolSize(25)
                }
            }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: true) }
        case .area where drawing.isContinuous:
            Chart(points) { point in
                AreaMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
                    .opacity(0.6)
                LineMark(x: .value("x", point.x ?? 0), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
            }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: true) }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
                if showsDots {
                    PointMark(x: .value("Label", point.label), y: .value("Value", point.value))
                        .foregroundStyle(seriesColour)
                        .symbolSize(25)
                }
            }
            .chartXAxis { categoryAxis }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: false) }
        case .area:
            Chart(points) { point in
                AreaMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
                    .opacity(0.6)
                LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
                    .foregroundStyle(seriesColour)
            }
            .chartXAxis { categoryAxis }
            .chartOverlay { proxy in hoverLayer(proxy, continuous: false) }
        }
    }

    /// Names along the axis, thinned so they never sit on each other: every one while
    /// they fit, every n-th past that, and upright once there are many. The readout
    /// still names whichever point the pointer is on.
    @AxisContentBuilder
    private var categoryAxis: some AxisContent {
        let labels = ChartSpec.axisLabels(points)
        let isDense = labels.count > ChartBudget.axisLabels / 2
        AxisMarks(values: labels) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(collisionResolution: .greedy, orientation: isDense ? .verticalReversed : .horizontal) {
                if let label = value.as(String.self) {
                    Text(Self.shortened(label))
                }
            }
        }
    }

    /// An axis label short enough to stand beside its neighbours.
    static func shortened(_ label: String, to limit: Int = 18) -> String {
        label.count > limit ? label.prefix(limit - 1) + "…" : label
    }

    private func hoverLayer(_ proxy: ChartProxy, continuous: Bool) -> some View {
        ChartHoverLayer(proxy: proxy, drawing: drawing, isContinuous: continuous, hover: hover, colour: seriesColour)
    }
}

/// Reads the point under the pointer and marks it, above the chart rather than in it:
/// the marks are not touched, so a hover costs one lookup and two small shapes.
private struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let drawing: ChartDrawing
    let isContinuous: Bool
    let hover: ChartHover
    let colour: Color

    private static let markerSize: CGFloat = DesignTokens.Spacing.sm

    var body: some View {
        GeometryReader { geometry in
            let frame = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case let .active(location) = phase else {
                            set(nil)
                            return
                        }
                        set(point(atX: location.x - frame.origin.x))
                    }
                if let point = hover.point, let place = place(of: point) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: frame.height)
                        .position(x: frame.minX + place.x, y: frame.midY)
                        .allowsHitTesting(false)
                    Circle()
                        .fill(colour)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .frame(width: Self.markerSize, height: Self.markerSize)
                        .position(x: frame.minX + place.x, y: frame.minY + place.y)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Written only when it changes: a pointer moving within one bar redraws nothing.
    private func set(_ point: ChartPoint?) {
        if hover.point?.id != point?.id { hover.point = point }
    }

    private func point(atX x: CGFloat) -> ChartPoint? {
        let points = drawing.plot.points
        let position: Int?
        if isContinuous {
            position = proxy.value(atX: x, as: Double.self).flatMap { drawing.index.nearest(toX: $0) }
        } else {
            position = proxy.value(atX: x, as: String.self).flatMap { drawing.index.position(ofLabel: $0) }
        }
        return position.flatMap { points.indices.contains($0) ? points[$0] : nil }
    }

    private func place(of point: ChartPoint) -> CGPoint? {
        let y = proxy.position(forY: point.value)
        let x: CGFloat? =
            isContinuous
            ? proxy.position(forX: point.x ?? Double(point.id)) : proxy.position(forX: point.label)
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Choosing a column among many

/// A column pop-up for a result with more columns than a menu can show: the current
/// choice as a button, and behind it a list that narrows as its name is typed.
private struct SearchableColumnPicker: View {
    let choices: [(index: Int, name: String, type: String)]
    @Binding var selection: Int

    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var isSearching: Bool

    private var matches: [(index: Int, name: String, type: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return choices }
        return choices.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(choices.first { $0.index == selection }?.name ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: Icon.chevronDown)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(choices.count) columns; type to find one")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: Icon.search).foregroundStyle(.secondary)
                    TextField("Find a column", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearching)
                        .onSubmit {
                            if let first = matches.first { choose(first.index) }
                        }
                }
                .padding(DesignTokens.Spacing.sm)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.index) { choice in
                            Button {
                                choose(choice.index)
                            } label: {
                                HStack(spacing: DesignTokens.Spacing.sm) {
                                    Text(choice.name).lineLimit(1)
                                    Spacer(minLength: DesignTokens.Spacing.sm)
                                    Text(choice.type).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, DesignTokens.Spacing.sm)
                                .padding(.vertical, DesignTokens.Spacing.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    if choice.index == selection {
                                        Rectangle().fill(Color.accentColor.opacity(0.18))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.isEmpty {
                            Text("No column matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(DesignTokens.Spacing.sm)
                        }
                    }
                }
                .frame(maxHeight: DesignTokens.Metrics.inspectorWidth)
            }
            .frame(width: DesignTokens.Metrics.inspectorWidth)
            .onAppear { isSearching = true }
        }
    }

    private func choose(_ index: Int) {
        selection = index
        isPresented = false
    }
}
