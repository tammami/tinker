import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// The three tools the Tools menu offers, Navicat's names.
public enum ToolKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case dataTransfer
    case dataSync
    case structureSync

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataTransfer: "Data Transfer"
        case .dataSync: "Data Synchronization"
        case .structureSync: "Structure Synchronization"
        }
    }

    public var icon: String {
        switch self {
        case .dataTransfer: Icon.transfer
        case .dataSync: Icon.sync
        case .structureSync: Icon.structureSync
        }
    }

    var subtitle: String {
        switch self {
        case .dataTransfer:
            "Copy tables, views and functions — structure and data — from one database to another, or to a file."
        case .dataSync:
            "Make the target's rows match the source's, table by table, by primary key. Compare first; nothing changes until you apply."
        case .structureSync:
            "Compare every table's structure and write the DDL that would make the target match. Read it before it runs."
        }
    }
}

/// A tool waiting for its wizard, with what the tree offered as the source.
public struct ToolRequest: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let kind: ToolKind
    public let connectionID: UUID?
    public let schema: SchemaRef?

    public init(kind: ToolKind, connectionID: UUID? = nil, schema: SchemaRef? = nil) {
        self.kind = kind
        self.connectionID = connectionID
        self.schema = schema
    }
}

/// One end of a transfer: a connection, a database, a schema — and what is known about it.
@MainActor
@Observable
final class EndpointModel {
    var connectionID: UUID?
    var database = ""
    var schema = ""
    private(set) var databases: [String] = []
    private(set) var schemas: [String] = []
    /// Lines for the Information pane.
    private(set) var information: [String] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var tables: [TableInfo] = []
    private(set) var routines: [RoutineInfo] = []

    private let environment: AppEnvironment

    init(environment: AppEnvironment, connectionID: UUID?, schema: SchemaRef?) {
        self.environment = environment
        self.connectionID = connectionID
        database = schema?.database ?? ""
        self.schema = schema?.schema ?? ""
    }

    var config: ConnectionConfig? { environment.connections.first { $0.id == connectionID } }
    var dialect: SQLDialect { config?.dialect ?? .postgresql }
    var isMySQL: Bool { dialect == .mysql }

    var schemaRef: SchemaRef? {
        guard connectionID != nil, !database.isEmpty else { return nil }
        if isMySQL { return SchemaRef.mysql(database) }
        guard !schema.isEmpty else { return nil }
        return SchemaRef(database: database, schema: schema)
    }

    /// `name · database · schema`, for the header.
    var label: String {
        guard let config else { return "Choose a connection" }
        var parts = [config.name]
        if !database.isEmpty { parts.append(database) }
        if !isMySQL, !schema.isEmpty { parts.append(schema) }
        return parts.joined(separator: " · ")
    }

    /// Loads the databases of the connection, keeping the chosen one when it is there.
    func loadConnection() async {
        guard let connectionID, let session = environment.session(for: connectionID) else {
            databases = []
            schemas = []
            information = []
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let version = try await session.connect()
            let found = try await session.introspection(.databases) { try await $0.databases() }
            databases = found.map(\.name)
            if !databases.contains(database) {
                database = databases.first { $0 == session.config.database } ?? databases.first ?? ""
            }
            information = [
                version.description,
                "\(session.config.host):\(session.config.port) as \(session.config.user)",
                "\(databases.count) database\(databases.count == 1 ? "" : "s")",
            ]
            await loadDatabase()
        } catch {
            self.error = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Loads the schemas of the database (PostgreSQL) and then the objects of the schema.
    func loadDatabase() async {
        guard let connectionID, !database.isEmpty else { return }
        if isMySQL {
            schema = database
            await loadSchema()
            return
        }
        guard let session = environment.session(for: connectionID, database: database) else { return }
        do {
            _ = try await session.connect()
            let name = database
            let found = try await session.introspection(.schemas(database: name)) { try await $0.schemas(in: name) }
            schemas = found.filter { !$0.isSystem }.map(\.name)
            if !schemas.contains(schema) { schema = schemas.contains("public") ? "public" : schemas.first ?? "" }
            await loadSchema()
        } catch {
            self.error = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    func loadSchema() async {
        guard let connectionID, let ref = schemaRef,
            let session = environment.session(for: connectionID, database: isMySQL ? nil : database)
        else {
            tables = []
            routines = []
            return
        }
        do {
            _ = try await session.connect()
            tables = try await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }
                .filter { $0.kind != .systemTable }
            routines = (try? await session.introspection(.routines(ref)) { try await $0.routines(in: ref) }) ?? []
            let base = tables.filter { $0.kind.isEditable }.count
            let views = tables.count - base
            let size = tables.compactMap(\.sizeBytes).reduce(0, +)
            var lines = Array(information.prefix(3))
            lines.append(
                "\(ref.schema): \(base) table\(base == 1 ? "" : "s"), \(views) view\(views == 1 ? "" : "s"), \(routines.count) routine\(routines.count == 1 ? "" : "s")"
            )
            if size > 0 { lines.append("\(TransferFormat.bytes(size)) on disk") }
            information = lines
        } catch {
            self.error = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

/// The Data Transfer / Data Synchronization / Structure Synchronization wizard: where
/// from and where to, which objects, then run.
struct ToolsWizardSheet: View {
    let request: ToolRequest
    let environment: AppEnvironment
    let onOpenScript: (UUID, String) -> Void
    let onDismiss: () -> Void

    @State private var source: EndpointModel
    @State private var target: EndpointModel
    @State private var controller: TransferController
    @State private var step = 1
    @State private var typedName = ""
    @State private var targetIsFile = false
    @State private var selectedTables: Set<String> = []
    @State private var selectedViews: Set<String> = []
    @State private var selectedRoutines: Set<String> = []
    @State private var allTables = true
    @State private var allViews = true
    @State private var allRoutines = true
    @State private var objectFilter = ""
    // Transfer options
    @State private var content: DumpOptions.Content = .structureAndData
    @State private var dropFirst = false
    @State private var compress = false
    // Data sync options
    @State private var syncOptions = DataSyncOptions()
    @State private var hasCompared = false
    // Structure sync options
    @State private var includeDestructive = false
    @State private var dropExtraTables = false
    @State private var selectedReport: String?

    init(
        request: ToolRequest, environment: AppEnvironment, onOpenScript: @escaping (UUID, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.request = request
        self.environment = environment
        self.onOpenScript = onOpenScript
        self.onDismiss = onDismiss
        let firstConnection = request.connectionID ?? environment.connections.first?.id
        _source = State(
            initialValue: EndpointModel(environment: environment, connectionID: firstConnection, schema: request.schema)
        )
        let dialect = environment.connections.first { $0.id == firstConnection }?.dialect
        let other =
            environment.connections.first { $0.id != firstConnection && $0.dialect == dialect }?.id ?? firstConnection
        _target = State(initialValue: EndpointModel(environment: environment, connectionID: other, schema: nil))
        _controller = State(initialValue: TransferController(environment: environment))
    }

    private var kind: ToolKind { request.kind }
    private var dialect: SQLDialect { source.dialect }

    /// Connections of the source's kind only; the tools never cross engines.
    private var candidateConnections: [ConnectionConfig] {
        environment.connections.filter { $0.dialect == dialect }
    }

    private var baseTables: [TableInfo] { source.tables.filter { $0.kind.isEditable } }
    private var views: [TableInfo] { source.tables.filter { !$0.kind.isEditable } }

    private var chosenTables: [TableInfo] {
        allTables ? baseTables : baseTables.filter { selectedTables.contains($0.name) }
    }
    private var chosenViews: [TableInfo] {
        allViews ? views : views.filter { selectedViews.contains($0.name) }
    }

    private var isEverythingChosen: Bool {
        allTables && allViews && allRoutines
    }

    private var canLeaveStep1: Bool {
        guard source.schemaRef != nil else { return false }
        if kind == .dataTransfer, targetIsFile { return true }
        guard let targetRef = target.schemaRef else { return false }
        return !(target.connectionID == source.connectionID && targetRef == source.schemaRef)
    }

    private var canStart: Bool {
        switch kind {
        case .dataTransfer:
            return !chosenTables.isEmpty || !chosenViews.isEmpty || (allRoutines && !source.routines.isEmpty)
        case .dataSync, .structureSync: return !chosenTables.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 1: endpointsPage
                case 2: objectsPage
                default: runPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 900, height: 620)
        .task {
            await source.loadConnection()
            await target.loadConnection()
            await applyDemoSettings()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: kind.icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.headline)
                Text(kind.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            HStack(spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(source.config?.name ?? "Source").font(.callout.weight(.medium)).lineLimit(1)
                    Text(endpointLine(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: Icon.database).foregroundStyle(.green)
                Image(systemName: Icon.goTo).foregroundStyle(.secondary)
                Image(systemName: targetIsFile && kind == .dataTransfer ? Icon.text : Icon.database).foregroundStyle(
                    Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(targetIsFile && kind == .dataTransfer ? "File" : (target.config?.name ?? "Target"))
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(targetIsFile && kind == .dataTransfer ? (compress ? ".sql.gz" : ".sql") : endpointLine(target))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 380)
            stepIndicator
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private func endpointLine(_ endpoint: EndpointModel) -> String {
        guard !endpoint.database.isEmpty else { return "—" }
        return endpoint.isMySQL || endpoint.schema.isEmpty
            ? endpoint.database : "\(endpoint.database) · \(endpoint.schema)"
    }

    private var stepIndicator: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(1 ... 3, id: \.self) { number in
                Circle()
                    .fill(number <= step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .help("Step \(step) of 3")
    }

    // MARK: - Step 1

    private var endpointsPage: some View {
        HStack(alignment: .top, spacing: 0) {
            endpointPanel(title: "Source", model: source, isTarget: false)
            VStack {
                Spacer()
                Button {
                    swapEndpoints()
                } label: {
                    Image(systemName: Icon.transfer)
                }
                .help("Swap source and target")
                .disabled(targetIsFile && kind == .dataTransfer)
                Spacer()
            }
            .frame(width: 48)
            endpointPanel(title: "Target", model: target, isTarget: true)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private func endpointPanel(title: String, model: EndpointModel, isTarget: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Text(title).font(.headline).foregroundStyle(Color.accentColor)
                Spacer()
                if isTarget, kind == .dataTransfer {
                    Picker("", selection: $targetIsFile) {
                        Label("Connection", systemImage: Icon.connection).tag(false)
                        Label("File", systemImage: Icon.text).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            if isTarget, targetIsFile, kind == .dataTransfer {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("The objects are written to a .sql or .sql.gz dump you choose when you start.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Compress with gzip", isOn: $compress)
                }
                .padding(.top, DesignTokens.Spacing.sm)
                Spacer()
            } else {
                @Bindable var model = model
                FieldRow(label: "Connection", labelWidth: 84) {
                    Picker("", selection: $model.connectionID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(candidateConnections) { config in Text(config.name).tag(UUID?.some(config.id)) }
                    }
                    .labelsHidden()
                    .onChange(of: model.connectionID) { _, _ in Task { await model.loadConnection() } }
                }
                FieldRow(label: "Database", labelWidth: 84) {
                    Picker("", selection: $model.database) {
                        ForEach(model.databases, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .disabled(model.databases.isEmpty)
                    .onChange(of: model.database) { _, _ in Task { await model.loadDatabase() } }
                }
                if !model.isMySQL {
                    FieldRow(label: "Schema", labelWidth: 84) {
                        Picker("", selection: $model.schema) {
                            ForEach(model.schemas, id: \.self) { name in Text(name).tag(name) }
                        }
                        .labelsHidden()
                        .disabled(model.schemas.isEmpty)
                        .onChange(of: model.schema) { _, _ in Task { await model.loadSchema() } }
                    }
                }
                Divider().padding(.vertical, DesignTokens.Spacing.xs)
                Text("Information").font(.headline).foregroundStyle(Color.accentColor)
                if model.isLoading {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = model.error {
                    InlineBanner(kind: .error, message: error, onDismiss: {})
                } else {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(model.information, id: \.self) { line in
                            Text(line).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swapEndpoints() {
        let sourceID = source.connectionID
        let sourceDatabase = source.database
        let sourceSchema = source.schema
        source.connectionID = target.connectionID
        source.database = target.database
        source.schema = target.schema
        target.connectionID = sourceID
        target.database = sourceDatabase
        target.schema = sourceSchema
        Task {
            await source.loadConnection()
            await target.loadConnection()
        }
    }

    // MARK: - Step 2

    private var objectsPage: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Database Objects").font(.headline).foregroundStyle(Color.accentColor)
                objectList
                TextField("Search", text: $objectFilter)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 420)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text("Options").font(.headline).foregroundStyle(Color.accentColor)
                optionsPane
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private var objectList: some View {
        List {
            objectSection(
                title: "Tables", icon: Icon.table, items: baseTables.map(\.name), all: $allTables,
                selected: $selectedTables)
            if kind == .dataTransfer {
                objectSection(
                    title: "Views", icon: Icon.view, items: views.map(\.name), all: $allViews, selected: $selectedViews)
                objectSection(
                    title: "Functions and procedures", icon: Icon.function, items: source.routines.map(\.name),
                    all: $allRoutines, selected: $selectedRoutines, allowsCustom: false)
            }
        }
        .listStyle(.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private func objectSection(
        title: String, icon: String, items: [String], all: Binding<Bool>, selected: Binding<Set<String>>,
        allowsCustom: Bool = true
    ) -> some View {
        let shown = objectFilter.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(objectFilter) }
        Section {
            Toggle(isOn: all) {
                Label("All \(title.lowercased()) during execution (\(items.count))", systemImage: icon)
            }
            .toggleStyle(.checkbox)
            if allowsCustom {
                DisclosureGroup {
                    ForEach(shown, id: \.self) { name in
                        Toggle(
                            isOn: Binding(
                                get: { selected.wrappedValue.contains(name) },
                                set: { on in
                                    if on {
                                        selected.wrappedValue.insert(name)
                                    } else {
                                        selected.wrappedValue.remove(name)
                                    }
                                })
                        ) {
                            Label(name, systemImage: icon).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(all.wrappedValue)
                    }
                } label: {
                    Text("Custom (\(selected.wrappedValue.count)/\(items.count))")
                        .foregroundStyle(all.wrappedValue ? .secondary : .primary)
                }
            }
        } header: {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private var optionsPane: some View {
        switch kind {
        case .dataTransfer:
            Picker("Content", selection: $content) {
                ForEach(DumpOptions.Content.allCases) { value in Text(value.title).tag(value) }
            }
            .frame(maxWidth: 320)
            Toggle("DROP … IF EXISTS before each object", isOn: $dropFirst)
            Text(
                dialect == .postgresql
                    ? "Rows travel as COPY blocks; on the same server a table of any size crosses with the memory of one batch."
                    : "Rows travel as INSERT batches with foreign key checks off while loading."
            )
            .font(.caption).foregroundStyle(.secondary)
        case .dataSync:
            Toggle("Insert rows the target lacks", isOn: $syncOptions.insert)
            Toggle("Update rows that differ", isOn: $syncOptions.update)
            Toggle("Delete rows the source lacks", isOn: $syncOptions.delete)
            Text(
                "Rows are matched by the target's primary key, read in key order on both sides and merged as they stream, so nothing is held in memory. Compare first; Apply runs every UPDATE and DELETE by key and checks it touched one row."
            )
            .font(.caption).foregroundStyle(.secondary)
        case .structureSync:
            Toggle("Include destructive statements (dropped columns, narrowed types)", isOn: $includeDestructive)
            Toggle("Drop tables the source does not have", isOn: $dropExtraTables)
            Text(
                "The script is generated, not run: read it, open it in a query tab, or run it on the target from here."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 3

    private var runPage: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            switch kind {
            case .dataTransfer:
                if controller.phase == .idle {
                    EmptyStateView(
                        icon: kind.icon, title: "Ready to transfer",
                        message: "\(chosenTables.count) table\(chosenTables.count == 1 ? "" : "s")"
                            + (kind == .dataTransfer
                                ? ", \(chosenViews.count) view\(chosenViews.count == 1 ? "" : "s")" : "")
                            + " from \(source.label) to \(targetIsFile ? "a file" : target.label).")
                } else {
                    TransferProgressView(controller: controller)
                    Spacer()
                }
            case .dataSync:
                if controller.phase != .idle { TransferProgressView(controller: controller) }
                if controller.syncReports.isEmpty, controller.phase == .idle {
                    EmptyStateView(
                        icon: kind.icon, title: "Compare first",
                        message: "Compare reads both sides and lists what differs; nothing is written until you apply.")
                } else {
                    syncReportList
                }
            case .structureSync:
                if controller.phase != .idle { TransferProgressView(controller: controller) }
                if let result = controller.schemaResult {
                    structureResult(result)
                } else if controller.phase == .idle {
                    EmptyStateView(
                        icon: kind.icon, title: "Compare first",
                        message:
                            "Every chosen table's structure is compared and the DDL to make the target match is written out."
                    )
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private var syncReportList: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            SimpleTable(
                columns: [
                    SimpleTable.Column(title: "Table", width: 140),
                    SimpleTable.Column(title: "Source", width: 64, isNumeric: true),
                    SimpleTable.Column(title: "Target", width: 64, isNumeric: true),
                    SimpleTable.Column(title: "Insert", width: 56, isNumeric: true),
                    SimpleTable.Column(title: "Update", width: 56, isNumeric: true),
                    SimpleTable.Column(title: "Delete", width: 56, isNumeric: true),
                    SimpleTable.Column(title: "Note", width: 210),
                ],
                rows: controller.syncReports.map { report in
                    [
                        report.source.name, TransferFormat.count(report.sourceRows),
                        TransferFormat.count(report.targetRows),
                        TransferFormat.count(report.inserts), TransferFormat.count(report.updates),
                        TransferFormat.count(report.deletes),
                        report.error ?? report.skippedReason
                            ?? (report.applied > 0
                                ? "\(TransferFormat.count(report.applied)) applied"
                                : (report.isIdentical ? "identical" : "")),
                    ]
                },
                monospaced: false
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(
                    Color.primary.opacity(0.1)))
            samplesPane
                .frame(width: 220)
        }
    }

    private var samplesPane: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Examples").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(controller.syncReports.filter { !$0.samples.isEmpty }) { report in
                        Text(report.source.name).font(.caption.weight(.semibold))
                        ForEach(report.samples.prefix(12)) { sample in
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                                Text(sample.kind == .insert ? "+" : sample.kind == .delete ? "−" : "~")
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .foregroundStyle(
                                        sample.kind == .insert ? .green : sample.kind == .delete ? .red : .orange)
                                Text(sample.detail.isEmpty ? sample.key : "\(sample.key): \(sample.detail)")
                                    .font(.system(.caption, design: .monospaced)).lineLimit(2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.sm)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius).strokeBorder(
                    Color.primary.opacity(0.1)))
        }
    }

    private func structureResult(_ result: SchemaSyncResult) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            SimpleTable(
                columns: [
                    SimpleTable.Column(title: "Table"),
                    SimpleTable.Column(title: "Result", width: 70),
                    SimpleTable.Column(title: "Statements", width: 76, isNumeric: true),
                    SimpleTable.Column(title: "Destructive", width: 80, isNumeric: true),
                ],
                rows: result.items.map { item in
                    [item.name, item.kind.rawValue, String(item.statements.count), String(item.destructiveCount)]
                },
                monospaced: false
            )
            .frame(width: 430)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(
                    Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Script").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    Text(result.script(includingDestructive: includeDestructive, droppingExtraTables: dropExtraTables))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Spacing.sm)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius).strokeBorder(
                        Color.primary.opacity(0.1)))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let config = target.config, config.isProduction, !targetIsFile {
                ProductionGate(
                    connectionName: config.name, requiresTypedName: step == 3 && kind == .structureSync,
                    typed: $typedName)
            }
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(controller.phase == .finished && step == 3 ? "Close" : "Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if step > 1 {
                    Button("Back") { step -= 1 }
                }
                if step < 3 {
                    Button("Next") {
                        step += 1
                        if step == 2, source.tables.isEmpty { Task { await source.loadSchema() } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 ? !canLeaveStep1 : !canStart)
                } else {
                    runButtons
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(.bar)
    }

    @ViewBuilder
    private var runButtons: some View {
        switch kind {
        case .dataTransfer:
            if controller.phase != .finished {
                Button {
                    startTransfer()
                } label: {
                    Label("Start", systemImage: Icon.run)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        case .dataSync:
            if controller.syncReports.isEmpty {
                Button {
                    startDataSync(apply: false)
                } label: {
                    Label("Compare", systemImage: Icon.search)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    startDataSync(apply: false)
                } label: {
                    Label("Compare", systemImage: Icon.search)
                }
            }
            Button {
                startDataSync(apply: true)
            } label: {
                Label("Apply", systemImage: Icon.run)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!controller.syncReports.contains { $0.differences > 0 && $0.error == nil })
        case .structureSync:
            if controller.schemaResult == nil {
                Button {
                    startStructureCompare()
                } label: {
                    Label("Compare", systemImage: Icon.search)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    startStructureCompare()
                } label: {
                    Label("Compare", systemImage: Icon.search)
                }
            }
            if let result = controller.schemaResult, let targetID = target.connectionID {
                Button {
                    onOpenScript(
                        targetID,
                        result.script(includingDestructive: includeDestructive, droppingExtraTables: dropExtraTables))
                    onDismiss()
                } label: {
                    Label("Open in Query Tab", systemImage: Icon.newQuery)
                }
                Button {
                    let statements = result.statements(
                        includingDestructive: includeDestructive, droppingExtraTables: dropExtraTables)
                    controller.runStatements(
                        statements, connectionID: targetID, database: target.database, dialect: dialect)
                } label: {
                    Label("Run on Target", systemImage: Icon.run)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    result.statements(includingDestructive: includeDestructive, droppingExtraTables: dropExtraTables)
                        .isEmpty
                        || !ProductionGate.passes(
                            productionName: target.config?.isProduction == true ? target.config?.name : nil,
                            requiresTypedName: true, typed: typedName)
                )
            }
        }
    }

    // MARK: - Actions

    /// `--ui-demo` can open the wizard on a later step against another database.
    private func applyDemoSettings() async {
        let defaults = UserDefaults.standard
        guard let targetDatabase = defaults.string(forKey: "uiDemo.toolTargetDatabase") else { return }
        defaults.removeObject(forKey: "uiDemo.toolTargetDatabase")
        target.database = targetDatabase
        await target.loadDatabase()
        let wantedStep = defaults.integer(forKey: "uiDemo.toolStep")
        defaults.removeObject(forKey: "uiDemo.toolStep")
        if wantedStep >= 2 {
            if source.tables.isEmpty { await source.loadSchema() }
            step = min(3, wantedStep)
        }
        if step == 3 {
            switch kind {
            case .dataSync: startDataSync(apply: false)
            case .structureSync: startStructureCompare()
            case .dataTransfer: break
            }
        }
    }

    private func startTransfer() {
        guard let sourceID = source.connectionID, let sourceRef = source.schemaRef, let config = source.config else {
            return
        }
        var options = DumpOptions.preferred(for: dialect)
        options.content = content
        options.includeDrop = dropFirst
        options.includeViews = allViews || !selectedViews.isEmpty
        options.includeRoutines = allRoutines
        let tables = chosenTables + chosenViews
        if targetIsFile {
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                (dialect == .mysql ? sourceRef.database : "\(sourceRef.database)_\(sourceRef.schema)")
                + (compress ? ".sql.gz" : ".sql")
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, var url = panel.url else { return }
            if compress, url.pathExtension != "gz" { url = url.appendingPathExtension("gz") }
            let request = DumpRequest(
                connectionID: sourceID, schema: sourceRef, tables: isEverythingChosen ? nil : tables)
            controller.dump(request, tables: tables, options: options, compress: compress, to: url)
            return
        }
        guard let targetID = target.connectionID, let targetRef = target.schemaRef else { return }
        let copied = CopiedObjects(
            connectionID: sourceID, connectionName: config.name, dialect: dialect, schema: sourceRef,
            tables: isEverythingChosen ? nil : tables)
        let request = PasteRequest(source: copied, targetConnectionID: targetID, targetSchema: targetRef)
        controller.paste(
            request, tables: tables, target: targetRef, createDatabase: false,
            renaming: DumpRenaming(schema: targetRef), options: options)
    }

    private func startDataSync(apply: Bool) {
        guard let sourceID = source.connectionID, let targetID = target.connectionID, let targetRef = target.schemaRef
        else { return }
        let pairs = chosenTables.map { (source: $0.ref, target: TableRef(schema: targetRef, name: $0.name)) }
        controller.synchronizeData(
            pairs: pairs, sourceConnectionID: sourceID, targetConnectionID: targetID, dialect: dialect,
            options: syncOptions, apply: apply)
    }

    private func startStructureCompare() {
        guard let sourceID = source.connectionID, let sourceRef = source.schemaRef,
            let targetID = target.connectionID, let targetRef = target.schemaRef
        else { return }
        controller.compareStructure(
            sourceSchema: sourceRef, sourceConnectionID: sourceID, targetSchema: targetRef,
            targetConnectionID: targetID,
            dialect: dialect, tables: allTables ? nil : selectedTables)
    }
}
