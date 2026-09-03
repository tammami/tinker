import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// The visual query builder: tables on the left, a canvas of cards joined by lines in the
/// middle, the clauses beneath it, and the SQL it produces on the right.
///
/// Drag a table onto the canvas (or double-click it); related tables are joined on
/// arrival from their foreign keys. Tick columns to select them; drag a column onto a
/// column of another card to join them by hand.
public struct QueryBuilderView: View {
    @Bindable var controller: QueryBuilderController
    let fontName: String
    let fontSize: Double
    let onOpenInQuery: (String) -> Void
    let onOpenTable: (TableRef) -> Void
    let onSchemaChanged: () -> Void

    @State private var isCreateViewPresented = false
    @State private var viewName = "new_view"

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.clearError() }
                Divider()
            }
            HSplitView {
                tableList
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
                VSplitView {
                    BuilderCanvas(controller: controller)
                        .frame(minHeight: 220)
                    clauseEditor
                        .frame(minHeight: 160, idealHeight: 220)
                }
                .frame(minWidth: 480, maxWidth: .infinity)
                .layoutPriority(1)
                VSplitView {
                    sqlPane
                        .frame(minHeight: 120, idealHeight: 260)
                    previewPane
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 280, idealWidth: 380, maxWidth: 560)
            }
        }
        .task { await controller.loadTables() }
        .sheet(isPresented: $isCreateViewPresented) { createViewSheet }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        PaneBar {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                Image(systemName: Icon.builder).foregroundStyle(Color.accentColor)
                Text("Query Builder").font(.system(size: 13, weight: .semibold))
                Text(controller.schema.schema).font(.caption).foregroundStyle(.tertiary)
            }
            BarDivider()
            Toggle("Distinct", isOn: $controller.model.isDistinct).toggleStyle(.checkbox)
            Spacer()
            Button {
                controller.runPreview()
            } label: {
                Label("Preview", systemImage: Icon.run)
            }
            .disabled(controller.sql == nil || controller.preview.isRunning)
            .help("Run the statement and show the rows below the SQL")
            Button {
                if let sql = controller.sql { onOpenInQuery(sql + ";") }
            } label: {
                Label("Open in Query Tab", systemImage: Icon.query)
            }
            .disabled(controller.sql == nil)
            Button {
                isCreateViewPresented = true
            } label: {
                Label("Create View…", systemImage: Icon.view)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.sql == nil)
        }
        .controlSize(.small)
    }

    // MARK: - Table list

    private var tableList: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Filter tables", text: $controller.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.barHeight)
            .background(.bar)
            Divider()
            if controller.visibleTables.isEmpty {
                EmptyStateView(icon: Icon.table, title: controller.isLoading ? "Reading…" : "No tables")
            } else {
                List(controller.visibleTables) { table in
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: table.kind.symbolName)
                            .foregroundStyle(table.kind.isEditable ? Color.accentColor : .purple)
                            .frame(width: DesignTokens.Metrics.iconWidth)
                        Text(table.name).lineLimit(1)
                        Spacer()
                        if controller.model.tables.contains(where: { $0.ref == table.ref }) {
                            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .draggable(table.name) {
                        Label(table.name, systemImage: table.kind.symbolName).padding(DesignTokens.Spacing.sm)
                    }
                    .onTapGesture(count: 2) {
                        Task { await controller.add(table.ref, at: nextFreeSpot()) }
                    }
                    .help("Drag onto the canvas, or double-click to add")
                }
                .listStyle(.plain)
            }
            Divider()
            StatusBarView {
                Text("Drag a table onto the canvas")
            }
        }
    }

    /// Somewhere to the right of what is already placed.
    private func nextFreeSpot() -> CGPoint {
        let maxX = controller.model.tables.map { $0.x + BuilderMetrics.cardWidth }.max() ?? 0
        return CGPoint(x: maxX + 60, y: 60)
    }

    // MARK: - Clauses

    private var clauseEditor: some View {
        VStack(spacing: 0) {
            PaneBar {
                Picker("Clause", selection: $controller.pane) {
                    ForEach(QueryBuilderController.Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .clipped()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    switch controller.pane {
                    case .select: selectPane
                    case .from: fromPane
                    case .whereClause: conditionsPane(\.conditions, title: "condition")
                    case .groupBy: groupByPane
                    case .having: conditionsPane(\.having, title: "condition")
                    case .orderBy: orderByPane
                    case .limit: limitPane
                    }
                }
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var placedTables: [QueryBuilderModel.Table] { controller.model.tables }

    /// A picker over every column of every placed table, keyed "tableID|column".
    private func columnPicker(
        table: Binding<UUID>, column: Binding<String>, allowStar: Bool = false, width: CGFloat = 220
    ) -> some View {
        Picker("Column", selection: Binding(
            get: { "\(table.wrappedValue.uuidString)|\(column.wrappedValue)" },
            set: { key in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return }
                table.wrappedValue = id
                column.wrappedValue = parts[1]
            }
        )) {
            ForEach(placedTables) { placed in
                if allowStar {
                    Text("\(placed.alias).*").tag("\(placed.id.uuidString)|*")
                }
                ForEach(controller.columnNames(of: placed.id), id: \.self) { name in
                    Text("\(placed.alias).\(name)").tag("\(placed.id.uuidString)|\(name)")
                }
            }
        }
        .labelsHidden()
        .frame(width: width)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: Icon.add) }
            .buttonStyle(.borderless)
            .disabled(placedTables.isEmpty)
    }

    private var firstColumn: (UUID, String)? {
        guard let table = placedTables.first(where: { $0.id == controller.selectedTable }) ?? placedTables.first else { return nil }
        return (table.id, controller.columnNames(of: table.id).first ?? "*")
    }

    @ViewBuilder
    private var selectPane: some View {
        if controller.model.fields.isEmpty {
            Text("No fields chosen: every column is selected. Tick columns on the canvas, or add fields here.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach($controller.model.fields) { $field in
            HStack(spacing: DesignTokens.Spacing.sm) {
                columnPicker(table: $field.table, column: $field.column, allowStar: true)
                Picker("Aggregate", selection: $field.aggregate) {
                    ForEach(QueryBuilderModel.Aggregate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                TextField("alias", text: Binding(get: { field.alias ?? "" }, set: { field.alias = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                IconButton(icon: "minus.circle", label: "Remove field") {
                    controller.model.fields.removeAll { $0.id == field.id }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        addButton("Add Field") {
            if let (table, column) = firstColumn { controller.model.fields.append(.init(table: table, column: column)) }
        }
    }

    @ViewBuilder
    private var fromPane: some View {
        ForEach(placedTables) { table in
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: Icon.table).foregroundStyle(Color.accentColor).frame(width: DesignTokens.Metrics.iconWidth)
                Text(table.ref.name).font(.callout)
                Text("AS").font(.caption).foregroundStyle(.tertiary)
                TextField("alias", text: Binding(
                    get: { table.alias },
                    set: { new in
                        if let index = controller.model.tables.firstIndex(where: { $0.id == table.id }) {
                            controller.model.tables[index].alias = new.isEmpty ? table.ref.name : new
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                IconButton(icon: "minus.circle", label: "Remove table") { controller.remove(table: table.id) }
                Spacer()
            }
            .controlSize(.small)
        }
        if !placedTables.isEmpty { Divider() }
        ForEach($controller.model.joins) { $join in
            HStack(spacing: DesignTokens.Spacing.sm) {
                Picker("Join", selection: $join.kind) {
                    ForEach(QueryBuilderModel.JoinKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                columnPicker(table: $join.leftTable, column: $join.leftColumn, width: 190)
                Text("=").foregroundStyle(.secondary)
                columnPicker(table: $join.rightTable, column: $join.rightColumn, width: 190)
                IconButton(icon: "minus.circle", label: "Remove join") {
                    controller.model.joins.removeAll { $0.id == join.id }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        addButton("Add Join") {
            guard placedTables.count >= 2 else { return }
            let a = placedTables[0], b = placedTables[1]
            controller.model.joins.append(.init(
                leftTable: a.id, leftColumn: controller.columnNames(of: a.id).first ?? "id",
                rightTable: b.id, rightColumn: controller.columnNames(of: b.id).first ?? "id"
            ))
        }
        .disabled(placedTables.count < 2)
    }

    private func conditionsPane(
        _ path: WritableKeyPath<QueryBuilderModel, [QueryBuilderModel.Condition]>, title: String
    ) -> some View {
        let binding = Binding(
            get: { controller.model[keyPath: path] },
            set: { controller.model[keyPath: path] = $0 }
        )
        return Group {
            ForEach(Array(binding.wrappedValue.enumerated()), id: \.element.id) { index, condition in
                let item = Binding(
                    get: { binding.wrappedValue.indices.contains(index) ? binding.wrappedValue[index] : condition },
                    set: { if binding.wrappedValue.indices.contains(index) { binding.wrappedValue[index] = $0 } }
                )
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if index > 0 {
                        Picker("Conjunction", selection: item.conjunction) {
                            ForEach(QueryBuilderModel.Condition.Conjunction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    } else {
                        Text("WHERE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    }
                    columnPicker(table: item.table, column: item.column, width: 190)
                    Picker("Operator", selection: item.op) {
                        ForEach(FilterOperator.allCases.filter { $0 != .anyContains }, id: \.self) { Text($0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    if item.wrappedValue.op.operandCount != 0 {
                        TextField(
                            item.wrappedValue.op == .inList ? "value, value" : item.wrappedValue.op == .between ? "low, high" : "value",
                            text: Binding(
                                get: { item.wrappedValue.values.compactMap(\.text).joined(separator: ", ") },
                                set: { text in
                                    let parts = text.split(separator: ",").map { DBValue.string($0.trimmingCharacters(in: .whitespaces)) }
                                    item.wrappedValue.values = (item.wrappedValue.op == .inList || item.wrappedValue.op == .between)
                                        ? parts : [.string(text)]
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    }
                    IconButton(icon: "minus.circle", label: "Remove \(title)") {
                        binding.wrappedValue.removeAll { $0.id == condition.id }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
            addButton("Add Condition") {
                if let (table, column) = firstColumn { binding.wrappedValue.append(.init(table: table, column: column)) }
            }
            Text("Values are written as literals so the statement can be saved as a view.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var groupByPane: some View {
        ForEach($controller.model.groupBy) { $field in
            HStack(spacing: DesignTokens.Spacing.sm) {
                columnPicker(table: $field.table, column: $field.column)
                IconButton(icon: "minus.circle", label: "Remove") {
                    controller.model.groupBy.removeAll { $0.id == field.id }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        addButton("Add Group Column") {
            if let (table, column) = firstColumn { controller.model.groupBy.append(.init(table: table, column: column)) }
        }
    }

    @ViewBuilder
    private var orderByPane: some View {
        ForEach($controller.model.orderBy) { $ordering in
            HStack(spacing: DesignTokens.Spacing.sm) {
                columnPicker(table: $ordering.table, column: $ordering.column)
                Picker("Direction", selection: $ordering.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .labelsHidden()
                .frame(width: 120)
                IconButton(icon: "minus.circle", label: "Remove") {
                    controller.model.orderBy.removeAll { $0.id == ordering.id }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        addButton("Add Ordering") {
            if let (table, column) = firstColumn { controller.model.orderBy.append(.init(table: table, column: column)) }
        }
    }

    private var limitPane: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            FieldRow(label: "Limit", labelWidth: 50) {
                TextField("none", value: $controller.model.limit, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            FieldRow(label: "Offset", labelWidth: 50) {
                TextField("0", value: $controller.model.offset, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: - SQL and preview

    private var sqlPane: some View {
        VStack(spacing: 0) {
            PaneBar {
                Label("SQL", systemImage: Icon.source).font(.caption.weight(.semibold))
                Spacer()
                IconButton(icon: Icon.copy, label: "Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.sql ?? "", forType: .string)
                }
                .disabled(controller.sql == nil)
            }
            .controlSize(.small)
            Divider()
            if let sql = controller.sql {
                ReadOnlySQLView(text: sql, dialect: controller.dialect, fontName: fontName, fontSize: fontSize)
                    .id(sql)
            } else {
                EmptyStateView(icon: Icon.builder, title: "Nothing to build yet",
                               message: "Drag a table from the list onto the canvas to begin.")
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        let preview = controller.preview
        VStack(spacing: 0) {
            PaneBar {
                Label("Preview", systemImage: Icon.data).font(.caption.weight(.semibold))
                Spacer()
                if preview.isRunning {
                    ProgressView().controlSize(.small)
                    IconButton(icon: Icon.stop, label: "Cancel") { preview.cancel() }
                }
                Text(preview.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .controlSize(.small)
            Divider()
            if let banner = preview.errorBanner {
                InlineBanner(kind: .error, message: banner.message, detail: banner.detail, hint: banner.hint) {
                    preview.errorBanner = nil
                }
                Divider()
            }
            if let grid = preview.selectedResult?.grid {
                DataGridView(model: grid, selection: Binding(get: { preview.selection }, set: { preview.selection = $0 }),
                             revision: preview.revision, delegate: preview)
            } else {
                EmptyStateView(icon: Icon.run, title: "No preview yet",
                               message: "Press Preview to run the statement and see its rows here.")
            }
        }
    }

    private var createViewSheet: some View {
        SheetFrame(title: "Create View", icon: Icon.view,
                   subtitle: "Saves the statement as a view in \(controller.schema.schema). CREATE OR REPLACE, so re-running updates it.") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "View name") {
                    TextField("name", text: $viewName).textFieldStyle(.roundedBorder)
                }
                if let statement = controller.model.createViewSQL(
                    name: TableRef(schema: controller.schema, name: viewName), dialect: controller.dialect
                ) {
                    StatementPreview(sql: statement)
                }
            }
        } footer: {
            Spacer()
            Button("Cancel") { isCreateViewPresented = false }.keyboardShortcut(.cancelAction)
            Button("Create") {
                Task {
                    if let ref = await controller.createView(named: viewName) {
                        isCreateViewPresented = false
                        onSchemaChanged()
                        onOpenTable(ref)
                    } else {
                        isCreateViewPresented = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(viewName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Canvas

/// The geometry every card shares, so join lines can be computed rather than measured.
enum BuilderMetrics {
    static let cardWidth: CGFloat = 200
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 22
    static let canvasPadding: CGFloat = 400

    static func cardHeight(columnCount: Int) -> CGFloat {
        headerHeight + rowHeight * CGFloat(columnCount + 1) + 6
    }

    /// Where a column's row sits on the card: `*` is row 0, the columns follow.
    static func rowCenterY(cardY: CGFloat, rowIndex: Int) -> CGFloat {
        cardY + headerHeight + rowHeight * (CGFloat(rowIndex) + 0.5) + 3
    }
}

/// The canvas: cards positioned by the model, join lines drawn beneath them, and the
/// drop target for tables from the list.
struct BuilderCanvas: View {
    @Bindable var controller: QueryBuilderController

    @State private var canvasSize = CGSize(width: 1_200, height: 800)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                    .frame(width: extent.width, height: extent.height)
                joinLines
                ForEach(controller.model.tables) { table in
                    TableCard(controller: controller, table: table)
                        .offset(x: table.x, y: table.y)
                }
            }
            .frame(width: extent.width, height: extent.height, alignment: .topLeading)
            .coordinateSpace(name: "canvas")
            .dropDestination(for: String.self) { items, location in
                guard let name = items.first,
                      let table = controller.availableTables.first(where: { $0.name == name })
                else { return false }
                let point = CGPoint(x: max(0, location.x - BuilderMetrics.cardWidth / 2), y: max(0, location.y - 14))
                Task { await controller.add(table.ref, at: point) }
                return true
            }
            .contextMenu {
                Button("Arrange Cards") { arrange() }
                    .disabled(controller.model.tables.isEmpty)
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if controller.model.tables.isEmpty {
                EmptyStateView(icon: Icon.builder, title: "Drop tables here",
                               message: "Related tables are joined automatically from their foreign keys. Drag a column onto another card's column to add a join by hand.")
                    .allowsHitTesting(false)
            }
        }
    }

    /// Big enough for every card plus room to drop the next one.
    private var extent: CGSize {
        let maxX = controller.model.tables.map { CGFloat($0.x) + BuilderMetrics.cardWidth }.max() ?? 0
        let maxY = controller.model.tables.map { table in
            CGFloat(table.y) + BuilderMetrics.cardHeight(columnCount: controller.columnNames(of: table.id).count)
        }.max() ?? 0
        return CGSize(width: max(1_200, maxX + BuilderMetrics.canvasPadding), height: max(700, maxY + BuilderMetrics.canvasPadding))
    }

    private func arrange() {
        var x: CGFloat = 40
        for table in controller.model.tables {
            controller.move(table: table.id, to: CGPoint(x: x, y: 40))
            x += BuilderMetrics.cardWidth + 80
        }
    }

    /// One line per join, from column row to column row, plus the line being dragged.
    private var joinLines: some View {
        Canvas { context, _ in
            for join in controller.model.joins {
                guard let from = anchor(table: join.leftTable, column: join.leftColumn),
                      let to = anchor(table: join.rightTable, column: join.rightColumn)
                else { continue }
                draw(context: &context, from: from, to: to, color: .accentColor, dashed: false)
            }
            if let pending = controller.pendingConnection,
               let from = anchor(table: pending.table, column: pending.column, towards: pending.point) {
                draw(context: &context, from: from, to: pending.point, color: .secondary, dashed: true)
            }
        }
        .frame(width: extent.width, height: extent.height)
        .allowsHitTesting(false)
    }

    private func draw(context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, dashed: Bool) {
        var path = Path()
        path.move(to: from)
        let dx = max(40, abs(to.x - from.x) / 2)
        let c1 = CGPoint(x: from.x + (to.x >= from.x ? dx : -dx), y: from.y)
        let c2 = CGPoint(x: to.x + (to.x >= from.x ? -dx : dx), y: to.y)
        path.addCurve(to: to, control1: c1, control2: c2)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : []))
        context.fill(Path(ellipseIn: CGRect(x: from.x - 3, y: from.y - 3, width: 6, height: 6)), with: .color(color))
        context.fill(Path(ellipseIn: CGRect(x: to.x - 3, y: to.y - 3, width: 6, height: 6)), with: .color(color))
    }

    /// The point on a card's edge beside a column row, on the side facing `towards`.
    private func anchor(table id: UUID, column: String, towards: CGPoint? = nil) -> CGPoint? {
        guard let table = controller.model.table(id) else { return nil }
        let names = controller.columnNames(of: id)
        let rowIndex = column == "*" ? 0 : (names.firstIndex(of: column).map { $0 + 1 } ?? 0)
        let y = BuilderMetrics.rowCenterY(cardY: CGFloat(table.y), rowIndex: rowIndex)
        let left = CGPoint(x: CGFloat(table.x), y: y)
        let right = CGPoint(x: CGFloat(table.x) + BuilderMetrics.cardWidth, y: y)
        let target = towards ?? otherEnd(of: id)
        return (target?.x ?? right.x) < CGFloat(table.x) + BuilderMetrics.cardWidth / 2 ? left : right
    }

    private func otherEnd(of id: UUID) -> CGPoint? {
        guard let join = controller.model.joins.first(where: { $0.leftTable == id || $0.rightTable == id }),
              let other = controller.model.table(join.leftTable == id ? join.rightTable : join.leftTable)
        else { return nil }
        return CGPoint(x: CGFloat(other.x) + BuilderMetrics.cardWidth / 2, y: CGFloat(other.y))
    }
}

/// One table on the canvas: a header to drag it by, `*`, and a row per column that can
/// be ticked into the SELECT list or dragged onto another card to join.
struct TableCard: View {
    @Bindable var controller: QueryBuilderController
    let table: QueryBuilderModel.Table

    @State private var dragStart: CGPoint?

    private var columnNames: [String] { controller.columnNames(of: table.id) }
    private var isSelected: Bool { controller.selectedTable == table.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                Image(systemName: Icon.table).font(.caption)
                Text(table.alias).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button {
                    controller.remove(table: table.id)
                } label: {
                    Image(systemName: Icon.close).font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Remove from the canvas")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: BuilderMetrics.headerHeight)
            .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.75))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        if dragStart == nil { dragStart = CGPoint(x: table.x, y: table.y) }
                        guard let start = dragStart else { return }
                        controller.move(table: table.id, to: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture { controller.selectedTable = table.id }

            VStack(spacing: 0) {
                columnRow("*", isStar: true)
                ForEach(columnNames, id: \.self) { name in columnRow(name, isStar: false) }
            }
            .padding(.vertical, 3)
        }
        .frame(width: BuilderMetrics.cardWidth)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private func columnRow(_ name: String, isStar: Bool) -> some View {
        let ticked = controller.isSelected(table: table.id, column: name)
        let joined = controller.model.joins.contains {
            ($0.leftTable == table.id && $0.leftColumn == name) || ($0.rightTable == table.id && $0.rightColumn == name)
        }
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                controller.toggleField(table: table.id, column: name)
            } label: {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(ticked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(ticked ? "Remove from SELECT" : "Add to SELECT")
            Text(name)
                .font(.system(size: 12, weight: isStar ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            if joined {
                Image(systemName: Icon.join).font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: BuilderMetrics.rowHeight)
        .contentShape(Rectangle())
        .gesture(
            // Dragging a column draws a line; releasing it over another card's column
            // makes a join. Stars cannot be joined on.
            DragGesture(minimumDistance: 6, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    guard !isStar else { return }
                    controller.pendingConnection = .init(table: table.id, column: name, point: value.location)
                }
                .onEnded { value in
                    defer { controller.pendingConnection = nil }
                    guard !isStar, let hit = hitTest(value.location), hit.table != table.id else { return }
                    controller.connect(table.id, name, to: hit.table, hit.column)
                }
        )
    }

    /// The card and column under a canvas point, by arithmetic rather than measurement.
    private func hitTest(_ point: CGPoint) -> (table: UUID, column: String)? {
        for other in controller.model.tables where other.id != table.id {
            let names = controller.columnNames(of: other.id)
            let frame = CGRect(
                x: other.x, y: other.y,
                width: BuilderMetrics.cardWidth, height: BuilderMetrics.cardHeight(columnCount: names.count)
            )
            guard frame.contains(point) else { continue }
            let rowIndex = Int((point.y - CGFloat(other.y) - BuilderMetrics.headerHeight - 3) / BuilderMetrics.rowHeight)
            guard rowIndex >= 1, rowIndex - 1 < names.count else { return nil }
            return (other.id, names[rowIndex - 1])
        }
        return nil
    }
}
