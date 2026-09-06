import DBCore
import Observation
import SwiftUI

/// Reads what a schema holds, for the Objects tab.
@MainActor
@Observable
public final class ObjectsController {
    public let schema: SchemaRef
    public let connectionID: UUID
    public let dialect: SQLDialect

    public private(set) var objects: [TableInfo] = []
    public private(set) var routines: [RoutineInfo] = []
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    public var search = ""
    public var sortColumn: Column = .name
    public var sortAscending = true
    public var kindFilter: KindFilter = .all

    public enum Column: String, CaseIterable, Identifiable {
        case name = "Name"
        case kind = "Kind"
        case rows = "Rows"
        case size = "Size"
        case engine = "Engine"
        case collation = "Collation"
        case comment = "Comment"

        public var id: String { rawValue }
    }

    public enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case tables = "Tables"
        case views = "Views"
        case routines = "Functions"

        public var id: String { rawValue }
    }

    private let environment: AppEnvironment

    public init(
        schema: SchemaRef, connectionID: UUID, dialect: SQLDialect, environment: AppEnvironment
    ) {
        self.schema = schema
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    public func load() async {
        guard let session = environment.session(for: connectionID, schema: schema) else {
            errorText = "No session for this connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await session.connect()
            let schema = schema
            async let tablesRead = session.introspection(.tables(schema)) { try await $0.tables(in: schema) }
            async let routinesRead = session.introspection(.routines(schema)) { try await $0.routines(in: schema) }
            objects = try await tablesRead
            routines = (try? await routinesRead) ?? []
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// What the list shows: the kind filter and the search applied, then the ordering.
    public var visible: [TableInfo] {
        let byKind: [TableInfo] =
            switch kindFilter {
            case .all: objects
            case .tables: objects.filter { $0.kind.isEditable }
            case .views: objects.filter { $0.kind == .view || $0.kind == .materializedView }
            case .routines: []
            }
        let filtered =
            search.isEmpty
            ? byKind
            : byKind.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted { left, right in
            let ordered: Bool =
                switch sortColumn {
                case .name: left.name.localizedStandardCompare(right.name) == .orderedAscending
                case .kind: left.kind.rawValue < right.kind.rawValue
                case .rows: (left.approximateRowCount ?? -1) < (right.approximateRowCount ?? -1)
                case .size: (left.sizeBytes ?? -1) < (right.sizeBytes ?? -1)
                case .engine: (left.engine ?? "") < (right.engine ?? "")
                case .collation: (left.collation ?? "") < (right.collation ?? "")
                case .comment: (left.comment ?? "") < (right.comment ?? "")
                }
            return sortAscending ? ordered : !ordered
        }
    }

    public var visibleRoutines: [RoutineInfo] {
        guard kindFilter == .routines || kindFilter == .all else { return [] }
        let filtered =
            search.isEmpty
            ? routines
            : routines.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func sort(by column: Column) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }
}

/// The Objects tab: every table in a schema, with what the catalog knows about it.
public struct ObjectsView: View {
    @Bindable var controller: ObjectsController
    let onOpen: (TableRef) -> Void
    let onOpenSource: (SourceObject) -> Void

    private let widths: [CGFloat?] = [260, 130, 100, 100, 100, 160, nil]
    @FocusState private var isSearchFocused: Bool

    public init(
        controller: ObjectsController,
        onOpen: @escaping (TableRef) -> Void,
        onOpenSource: @escaping (SourceObject) -> Void
    ) {
        self.controller = controller
        self.onOpen = onOpen
        self.onOpenSource = onOpenSource
    }

    public var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: Icon.schema).foregroundStyle(.teal)
                    Text(controller.schema.schema).font(.system(size: 13, weight: .semibold))
                    Text(controller.schema.database).font(.caption).foregroundStyle(.tertiary)
                }
                BarDivider()
                Picker("Kind", selection: $controller.kindFilter) {
                    ForEach(ObjectsController.KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: Icon.search).foregroundStyle(.secondary)
                    TextField("Filter by name", text: $controller.search)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .focusesOnSearchCommand($isSearchFocused)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(width: 220, height: 24)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.1))
                )
                IconButton(icon: Icon.refresh, label: "Re-read the catalog") {
                    Task { await controller.load() }
                }
            }
            .controlSize(.small)
            Divider()

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) {}
                Divider()
            }

            if controller.visible.isEmpty, controller.visibleRoutines.isEmpty {
                EmptyStateView(
                    icon: controller.isLoading ? Icon.refresh : Icon.objects,
                    title: controller.isLoading ? "Reading the catalog…" : "Nothing here",
                    message: controller.search.isEmpty ? nil : "No object matches “\(controller.search)”."
                )
            } else {
                list
            }

            Divider()
            StatusBarView {
                let tables = controller.visible.count
                let routines = controller.visibleRoutines.count
                Text(
                    "\(tables) object\(tables == 1 ? "" : "s")"
                        + (routines > 0 ? ", \(routines) function\(routines == 1 ? "" : "s")" : "")
                )
                .monospacedDigit()
                Spacer()
                // The figures are the server's estimates, and say so.
                Label("Row counts are the server's estimates, not a count", systemImage: Icon.info)
            }
        }
        .task(id: controller.schema.id) { await controller.load() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                if !controller.visible.isEmpty {
                    Section {
                        ForEach(Array(controller.visible.enumerated()), id: \.element.id) { index, object in
                            objectRow(object, index: index)
                        }
                    } header: {
                        header
                    }
                }
                if !controller.visibleRoutines.isEmpty {
                    Section {
                        ForEach(Array(controller.visibleRoutines.enumerated()), id: \.element.id) { index, routine in
                            routineRow(routine, index: index)
                        }
                    } header: {
                        SectionHeading(text: "Functions and procedures")
                            .background(.bar)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(ObjectsController.Column.allCases.enumerated()), id: \.element.id) {
                index, column in
                Button {
                    controller.sort(by: column)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(column.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if controller.sortColumn == column {
                            Image(systemName: controller.sortAscending ? Icon.sortAscending : Icon.sortDescending)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: widths[index], alignment: .leading)
                    .frame(maxWidth: widths[index] == nil ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: DesignTokens.Metrics.gridHeaderHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func objectRow(_ object: TableInfo, index: Int) -> some View {
        HStack(spacing: 0) {
            cell(widths[0]) {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: object.kind.symbolName)
                        .foregroundStyle(object.kind.isEditable ? Color.accentColor : .purple)
                        .frame(width: DesignTokens.Metrics.iconWidth)
                    Text(object.name)
                }
            }
            cell(widths[1]) { Text(object.kind.displayName).foregroundStyle(.secondary) }
            cell(widths[2], numeric: true) {
                Text(object.approximateRowCount.map { "~\($0)" } ?? "—").monospacedDigit()
            }
            cell(widths[3], numeric: true) { Text(Self.size(object.sizeBytes)).monospacedDigit() }
            cell(widths[4]) { Text(object.engine ?? "—").foregroundStyle(.secondary) }
            cell(widths[5]) { Text(object.collation ?? object.owner ?? "—").foregroundStyle(.secondary) }
            cell(widths[6]) { Text(object.comment ?? "").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .frame(height: 26)
        .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(object.ref) }
        .contextMenu {
            Button {
                onOpen(object.ref)
            } label: {
                Label("Open", systemImage: Icon.table)
            }
            if object.kind == .view || object.kind == .materializedView {
                Button {
                    onOpenSource(SourceObject(kind: .view(object.ref)))
                } label: {
                    Label("Open Definition", systemImage: Icon.source)
                }
            }
        }
    }

    private func routineRow(_ routine: RoutineInfo, index: Int) -> some View {
        HStack(spacing: 0) {
            cell(widths[0]) {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Image(systemName: routine.kind.symbolName)
                        .foregroundStyle(.orange)
                        .frame(width: DesignTokens.Metrics.iconWidth)
                    Text(routine.name)
                }
            }
            cell(widths[1]) { Text(routine.kind.rawValue.capitalized).foregroundStyle(.secondary) }
            cell(nil) {
                Text("(\(routine.signature))" + (routine.returnType.map { " → \($0)" } ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(height: 26)
        .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openRoutine(routine) }
        .contextMenu {
            Button {
                openRoutine(routine)
            } label: {
                Label("Open Definition", systemImage: Icon.source)
            }
        }
    }

    private func openRoutine(_ routine: RoutineInfo) {
        onOpenSource(
            SourceObject(
                kind: .routine(
                    schema: controller.schema, name: routine.name, signature: routine.signature, kind: routine.kind
                )))
    }

    private func cell<Content: View>(
        _ width: CGFloat?, numeric: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .lineLimit(1)
            .frame(width: width, alignment: numeric ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
    }

    /// Bytes as the catalog reports them, in the units a person reads.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
