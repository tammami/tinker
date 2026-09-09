import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// Dump a database, a schema or some tables to a `.sql` or `.sql.gz` file.
///
/// Structure only, structure and data, or data only; PostgreSQL data as COPY blocks
/// or INSERTs; every object optional. The file is written as the rows stream, so the
/// size of the database never matters to the app's memory. Opened from the Tools menu,
/// the sheet first asks which connection, database and schema to dump.
struct DumpSheet: View {
    let request: DumpRequest
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var controller: TransferController
    @State private var endpoint: EndpointModel
    @State private var options: DumpOptions
    @State private var compress = false
    @State private var tables: [TableInfo] = []
    @State private var selected: Set<String> = []
    @State private var isLoadingTables = false
    @State private var loadError: String?

    init(request: DumpRequest, environment: AppEnvironment, onDismiss: @escaping () -> Void) {
        self.request = request
        self.environment = environment
        self.onDismiss = onDismiss
        let dialect = environment.connections.first { $0.id == request.connectionID }?.dialect ?? .postgresql
        _controller = State(initialValue: TransferController(environment: environment))
        _endpoint = State(
            initialValue: EndpointModel(
                environment: environment, connectionID: request.connectionID, schema: request.schema))
        _options = State(initialValue: DumpOptions.preferred(for: dialect))
    }

    /// Where the dump reads from: the row that was clicked, or what the pickers say.
    private var connectionID: UUID {
        request.choosesSource ? (endpoint.connectionID ?? request.connectionID) : request.connectionID
    }
    private var schema: SchemaRef { request.choosesSource ? (endpoint.schemaRef ?? request.schema) : request.schema }
    private var config: ConnectionConfig? { environment.connections.first { $0.id == connectionID } }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }

    private var scopeTitle: String {
        if let tables = request.tables {
            return tables.count == 1 ? "Dump “\(tables[0].name)”" : "Dump \(tables.count) tables"
        }
        if request.choosesSource { return "Dump Database" }
        return dialect.hasSchemaLayer ? "Dump schema “\(schema.schema)”" : "Dump database “\(schema.database)”"
    }

    private var sourceLine: String {
        let name = config?.name ?? "connection"
        return dialect.hasSchemaLayer ? "\(name) · \(schema.database) · \(schema.schema)" : "\(name) · \(schema.database)"
    }

    private var chosenTables: [TableInfo] {
        request.tables ?? tables.filter { selected.contains($0.name) }
    }

    private var suggestedFileName: String {
        let base: String
        if let tables = request.tables, tables.count == 1 {
            base = tables[0].name
        } else {
            base = dialect.hasSchemaLayer ? "\(schema.database)_\(schema.schema)" : schema.database
        }
        return base + (compress ? ".sql.gz" : ".sql")
    }

    var body: some View {
        SheetFrame(
            title: scopeTitle, icon: Icon.export, subtitle: sourceLine, width: DesignTokens.Metrics.wideSheetWidth,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                if request.choosesSource {
                    sourcePicker
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.top, DesignTokens.Spacing.lg)
                        .disabled(controller.isRunning)
                }
                Form {
                    Section {
                        Picker("Content", selection: $options.content) {
                            ForEach(DumpOptions.Content.allCases) { content in Text(content.title).tag(content) }
                        }
                        if dialect == .postgresql, options.content.includesData {
                            Picker("Data as", selection: $options.dataStyle) {
                                ForEach(DumpOptions.DataStyle.allCases) { style in Text(style.title).tag(style) }
                            }
                        }
                        if options.content.includesData, options.dataStyle == .insert || dialect != .postgresql {
                            TextField("Rows per INSERT", value: $options.rowsPerInsert, format: .number)
                        }
                        Toggle("Compress with gzip (.sql.gz)", isOn: $compress)
                    }
                    if options.content.includesStructure {
                        Section("Structure") {
                            Toggle("DROP … IF EXISTS before each object", isOn: $options.includeDrop)
                            if request.tables == nil {
                                Toggle("Views", isOn: $options.includeViews)
                                Toggle("Functions and procedures", isOn: $options.includeRoutines)
                            }
                            Toggle("Triggers", isOn: $options.includeTriggers)
                            if dialect == .mysql {
                                Toggle(
                                    "Leave DEFINER out, so it restores under any account", isOn: $options.stripDefiners)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(
                    height: options.content.includesStructure
                        ? (request.tables == nil ? 350 : 290) + (dialect == .mysql ? 36 : 0) : 190
                )
                .disabled(controller.isRunning)

                if request.tables == nil {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        if isLoadingTables {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                ProgressView().controlSize(.small)
                                Text("Reading tables…").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                        } else if let loadError {
                            InlineBanner(kind: .error, message: loadError) { self.loadError = nil }
                        } else {
                            TransferTableList(tables: tables, selected: $selected)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.top, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.md)
                    .disabled(controller.isRunning)
                }

                if controller.phase != .idle {
                    TransferProgressView(controller: controller)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.md)
                }
            }
        } footer: {
            if let url = controller.writtenURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: Icon.open)
                }
            }
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(controller.phase == .finished ? "Close" : "Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if controller.phase != .finished {
                    Button {
                        chooseDestination()
                    } label: {
                        Label("Dump…", systemImage: Icon.export)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenTables.isEmpty && !(options.includeRoutines && request.tables == nil))
                }
            }
        }
        .task {
            if request.choosesSource {
                await endpoint.loadConnection()
            }
            await loadTables()
        }
    }

    /// Connection, database and schema pickers, for a dump started from the menu.
    private var sourcePicker: some View {
        @Bindable var endpoint = endpoint
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "Connection", labelWidth: 80) {
                    Picker("", selection: $endpoint.connectionID) {
                        ForEach(environment.connections) { config in Text(config.name).tag(UUID?.some(config.id)) }
                    }
                    .labelsHidden()
                    .onChange(of: endpoint.connectionID) { _, _ in
                        Task {
                            await endpoint.loadConnection()
                            options = DumpOptions.preferred(for: dialect)
                            await loadTables()
                        }
                    }
                }
                FieldRow(label: "Database", labelWidth: 70) {
                    Picker("", selection: $endpoint.database) {
                        ForEach(endpoint.databases, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .disabled(endpoint.databases.isEmpty)
                    .onChange(of: endpoint.database) { _, _ in
                        Task {
                            await endpoint.loadDatabase()
                            await loadTables()
                        }
                    }
                }
                if !endpoint.isFlat {
                    FieldRow(label: "Schema", labelWidth: 56) {
                        Picker("", selection: $endpoint.schema) {
                            ForEach(endpoint.schemas, id: \.self) { name in Text(name).tag(name) }
                        }
                        .labelsHidden()
                        .disabled(endpoint.schemas.isEmpty)
                        .onChange(of: endpoint.schema) { _, _ in Task { await loadTables() } }
                    }
                }
            }
            if let error = endpoint.error {
                InlineBanner(kind: .error, message: error, onDismiss: {})
            }
        }
    }

    private func loadTables() async {
        guard request.tables == nil else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }
        let ref = schema
        guard let session = environment.session(for: connectionID, database: ref.database) else { return }
        do {
            _ = try await session.connect()
            let all = try await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }
            tables = all.filter { $0.kind != .systemTable }
            selected = Set(tables.map(\.name))
            loadError = nil
        } catch {
            loadError = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // The panel may drop the double extension; the file's own name says what it is.
        if compress, url.pathExtension != "gz" { url = url.appendingPathExtension("gz") }
        var chosen = options
        if dialect != .postgresql { chosen.dataStyle = .insert }
        let resolved = DumpRequest(connectionID: connectionID, schema: schema, tables: request.tables)
        controller.dump(resolved, tables: chosenTables, options: chosen, compress: compress, to: url)
    }
}
