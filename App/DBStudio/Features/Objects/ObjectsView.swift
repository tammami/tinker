import DBCore
import Observation
import SwiftUI

/// Reads what a schema holds, for the Objects tab (SPEC §11.4).
@MainActor
@Observable
public final class ObjectsController {
    public let schema: SchemaRef
    public let connectionID: UUID
    public let dialect: SQLDialect

    public private(set) var objects: [TableInfo] = []
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    public var search = ""
    public var sortColumn: Column = .name
    public var sortAscending = true

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
        guard let session = environment.session(for: connectionID) else {
            errorText = "No session for this connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await session.connect()
            objects = try await session.introspection(.tables(schema)) {
                try await $0.tables(in: schema)
            }
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// What the list shows: the search applied, then the chosen ordering.
    public var visible: [TableInfo] {
        let filtered = search.isEmpty
            ? objects
            : objects.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted { left, right in
            let ordered: Bool = switch sortColumn {
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

    private let widths: [CGFloat?] = [240, 130, 110, 110, 110, 170, nil]

    public init(controller: ObjectsController, onOpen: @escaping (TableRef) -> Void) {
        self.controller = controller
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name", text: $controller.search)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 260)
                Spacer()
                Text("\(controller.visible.count) object\(controller.visible.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { Task { await controller.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read the catalog")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if let error = controller.errorText {
                ErrorBanner(message: error) { }
                Divider()
            }

            header
            Divider()

            if controller.visible.isEmpty {
                ContentUnavailableView(
                    controller.isLoading ? "Reading the catalog…" : "Nothing here",
                    systemImage: "tablecells"
                )
            } else {
                rows
            }

            Divider()
            HStack {
                // The figures are the server's estimates, and say so (ADR-0030).
                Text("Row counts are the server's estimates, not a count.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .task(id: controller.schema.id) { await controller.load() }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(ObjectsController.Column.allCases.enumerated()), id: \.element.id) {
                index, column in
                Button {
                    controller.sort(by: column)
                } label: {
                    HStack(spacing: 3) {
                        Text(column.rawValue)
                            .font(.caption.weight(.semibold))
                        if controller.sortColumn == column {
                            Image(systemName: controller.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .frame(width: widths[index], alignment: .leading)
                    .frame(maxWidth: widths[index] == nil ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(controller.visible.enumerated()), id: \.element.id) { index, object in
                    HStack(spacing: 0) {
                        cell(widths[0]) {
                            HStack(spacing: 5) {
                                Image(systemName: object.kind.symbolName)
                                    .foregroundStyle(.secondary)
                                Text(object.name)
                            }
                        }
                        cell(widths[1]) { Text(object.kind.rawValue) }
                        cell(widths[2]) {
                            Text(object.approximateRowCount.map { "~\($0)" } ?? "—")
                        }
                        cell(widths[3]) { Text(Self.size(object.sizeBytes)) }
                        cell(widths[4]) { Text(object.engine ?? "—") }
                        cell(widths[5]) { Text(object.collation ?? object.owner ?? "—") }
                        cell(widths[6]) { Text(object.comment ?? "") }
                    }
                    .padding(.vertical, 3)
                    .background(
                        index.isMultiple(of: 2)
                            ? Color.clear
                            : Color(nsColor: .alternatingContentBackgroundColors[1])
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(object.ref) }
                    .contextMenu {
                        Button("Open") { onOpen(object.ref) }
                    }
                }
            }
        }
    }

    private func cell<Content: View>(
        _ width: CGFloat?, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 6)
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
        return unit == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[unit])
    }
}
