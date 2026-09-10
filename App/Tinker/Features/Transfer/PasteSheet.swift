import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// Paste what Copy picked up — a table, some tables, a whole schema or database — into
/// another schema, database or connection of the same kind.
///
/// Rows stream straight from one connection to the other; nothing touches the disk.
/// On PostgreSQL the load goes through COPY, on MySQL through batched INSERTs.
struct PasteSheet: View {
    let request: PasteRequest
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var controller: TransferController
    @State private var targetConnectionID: UUID
    @State private var databases: [String] = []
    @State private var schemas: [String] = []
    @State private var database: String
    @State private var schema: String
    @State private var newDatabase = ""
    @State private var newSchema = ""
    @State private var useNewDatabase = false
    @State private var useNewSchema = false
    @State private var tableName = ""
    @State private var includeData = true
    @State private var replaceExisting = false
    @State private var selected: Set<String>
    @State private var isLoadingTargets = false
    @State private var typedName = ""
    @State private var loadError: String?
    @State private var existingTables: Set<String> = []

    init(request: PasteRequest, environment: AppEnvironment, onDismiss: @escaping () -> Void) {
        self.request = request
        self.environment = environment
        self.onDismiss = onDismiss
        _controller = State(initialValue: TransferController(environment: environment))
        _targetConnectionID = State(initialValue: request.targetConnectionID)
        let target = request.targetSchema
        _database = State(initialValue: target?.database ?? "")
        _schema = State(initialValue: target?.schema ?? request.source.schema.schema)
        _selected = State(initialValue: Set((request.source.tables ?? []).map(\.name)))
        _tableName = State(initialValue: request.source.tables?.count == 1 ? request.source.tables?[0].name ?? "" : "")
    }

    /// The target's engine: the paste is written in its terms, whatever the source speaks.
    private var dialect: SQLDialect { targetConfig?.dialect ?? request.source.dialect }
    /// True when the database is the schema — MySQL and SQLite — so there is no schema row to pick.
    private var isFlat: Bool { !dialect.hasSchemaLayer }
    private var isSingleTable: Bool { request.source.tables?.count == 1 }
    private var isCrossEngine: Bool { dialect != request.source.dialect }

    /// Every stored connection: a paste may cross engines.
    private var candidateConnections: [ConnectionConfig] { environment.connections }
    /// Folder-qualified titles, so two connections called the same read apart.
    private var connectionTitles: [UUID: String] { ConnectionConfig.distinctTitles(for: candidateConnections) }

    private var targetConfig: ConnectionConfig? { environment.connections.first { $0.id == targetConnectionID } }

    private var effectiveDatabase: String {
        useNewDatabase ? newDatabase.trimmingCharacters(in: .whitespaces) : database
    }
    private var effectiveSchema: String {
        isFlat ? effectiveDatabase : (useNewSchema ? newSchema.trimmingCharacters(in: .whitespaces) : schema)
    }

    private var targetRef: SchemaRef {
        SchemaRef.pseudoSchema(dialect, database: effectiveDatabase)
            ?? SchemaRef(database: effectiveDatabase, schema: effectiveSchema)
    }

    private var isSameSchema: Bool {
        targetConnectionID == request.source.connectionID && targetRef == request.source.schema
    }

    private var chosenTables: [TableInfo] {
        guard let tables = request.source.tables else { return [] }
        return tables.filter { selected.contains($0.name) }
    }

    private var pastedName: String {
        let trimmed = tableName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (request.source.tables?.first?.name ?? "") : trimmed
    }

    private var conflict: String? {
        if isSingleTable, isSameSchema, pastedName == request.source.tables?.first?.name {
            return "That is the table itself; give the copy another name."
        }
        if isSingleTable, existingTables.contains(pastedName), !replaceExisting {
            return "“\(pastedName)” already exists there. Choose another name or replace it."
        }
        if !isSingleTable, isSameSchema, !request.source.isWholeSchema || !useNewSchema && !useNewDatabase {
            return "Pasting into the very same place would only replace what is there."
        }
        return nil
    }

    private var canPaste: Bool {
        guard !effectiveDatabase.isEmpty, !effectiveSchema.isEmpty else { return false }
        if request.source.tables != nil, chosenTables.isEmpty { return false }
        return conflict == nil || replaceExisting
    }

    var body: some View {
        SheetFrame(
            title: "Paste \(request.source.label)", icon: Icon.paste,
            subtitle: "From \(request.source.connectionName) · \(sourceLine)",
            width: DesignTokens.Metrics.wideSheetWidth, contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section("Where") {
                        Picker("Connection", selection: $targetConnectionID) {
                            ForEach(candidateConnections) { config in
                                Label {
                                    Text(connectionTitles[config.id] ?? config.name)
                                } icon: {
                                    EngineMark(dialect: config.dialect, size: 14)
                                }
                                .tag(config.id)
                            }
                        }
                        .onChange(of: targetConnectionID) { _, _ in Task { await loadTargets() } }
                        if isCrossEngine {
                            Label(
                                "\(request.source.dialect.displayName) → \(dialect.displayName): tables are rebuilt in \(dialect.displayName)'s types with keys and indexes; views, triggers and check constraints stay behind.",
                                systemImage: Icon.warning
                            )
                            .font(.caption).foregroundStyle(.orange)
                        }
                        databaseRow
                        if !isFlat { schemaRow }
                        if isSingleTable {
                            TextField(
                                "Paste as", text: $tableName, prompt: Text(request.source.tables?.first?.name ?? ""))
                        }
                    }
                    Section("What") {
                        Toggle("Structure and data", isOn: $includeData)
                        Toggle("Replace tables that already exist there", isOn: $replaceExisting)
                    }
                }
                .formStyle(.grouped)
                .frame(height: (isSingleTable ? 372 : 336) + (isFlat ? 0 : 80))
                .disabled(controller.isRunning)

                if let tables = request.source.tables, tables.count > 1 {
                    TransferTableList(tables: tables, selected: $selected)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.md)
                        .disabled(controller.isRunning)
                }
                if let loadError {
                    InlineBanner(kind: .error, message: loadError) { self.loadError = nil }
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.sm)
                } else if let conflict, controller.phase == .idle {
                    InlineBanner(kind: .warning, message: conflict, onDismiss: {})
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.sm)
                }
                if controller.phase != .idle {
                    TransferProgressView(controller: controller)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.md)
                }
            }
        } footer: {
            if let targetConfig, targetConfig.isProduction {
                ProductionGate(connectionName: targetConfig.name, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(controller.phase == .finished ? "Close" : "Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if controller.phase != .finished {
                    Button {
                        run()
                    } label: {
                        Label("Paste", systemImage: Icon.paste)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !canPaste || isLoadingTargets
                            || !ProductionGate.passes(
                                productionName: targetConfig?.isProduction == true ? targetConfig?.name : nil,
                                requiresTypedName: true, typed: typedName)
                    )
                }
            }
        }
        .task { await loadTargets() }
        .onChange(of: database) { _, _ in Task { await loadSchemas() } }
        .onChange(of: schema) { _, _ in Task { await loadExistingTables() } }
        .onChange(of: useNewDatabase) { _, _ in Task { await loadExistingTables() } }
        .onChange(of: useNewSchema) { _, _ in Task { await loadExistingTables() } }
    }

    private var sourceLine: String {
        isFlat ? request.source.schema.database : "\(request.source.schema.database) · \(request.source.schema.schema)"
    }

    @ViewBuilder
    private var databaseRow: some View {
        Picker("Database", selection: $useNewDatabase) {
            Text("Existing").tag(false)
            Text("New").tag(true)
        }
        .pickerStyle(.segmented)
        if useNewDatabase {
            TextField("New database name", text: $newDatabase, prompt: Text(request.source.schema.database))
        } else {
            Picker("Database", selection: $database) {
                ForEach(databases, id: \.self) { name in Text(name).tag(name) }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var schemaRow: some View {
        Picker("Schema", selection: $useNewSchema) {
            Text("Existing").tag(false)
            Text("New").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(useNewDatabase)
        if useNewSchema || useNewDatabase {
            TextField(
                "Schema name", text: useNewDatabase ? .constant(request.source.schema.schema) : $newSchema,
                prompt: Text(request.source.schema.schema)
            )
            .disabled(useNewDatabase)
        } else {
            Picker("Schema", selection: $schema) {
                ForEach(schemas, id: \.self) { name in Text(name).tag(name) }
            }
            .labelsHidden()
        }
    }

    // MARK: - Targets

    private func loadTargets() async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }
        guard let session = environment.session(for: targetConnectionID) else { return }
        do {
            _ = try await session.connect()
            let found = try await session.introspection(.databases) { try await $0.databases() }
            databases = found.map(\.name)
            if !databases.contains(database) {
                database = databases.first { $0 == session.config.database } ?? databases.first ?? ""
            }
            if isFlat, request.source.isWholeSchema, request.targetSchema == nil {
                // A whole database usually goes to a database of its own name.
                useNewDatabase =
                    !databases.contains(request.source.schema.database)
                    || targetConnectionID == request.source.connectionID
                newDatabase =
                    targetConnectionID == request.source.connectionID
                    ? request.source.schema.database + "_copy" : request.source.schema.database
            }
            await loadSchemas()
            // A table pasted next to itself needs another name; offer the usual one.
            if isSingleTable, isSameSchema, let source = request.source.tables?.first?.name, pastedName == source {
                tableName = source + "_copy"
            }
        } catch {
            loadError = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private func loadSchemas() async {
        guard !isFlat, !database.isEmpty,
            let session = environment.session(for: targetConnectionID, database: database)
        else {
            await loadExistingTables()
            return
        }
        do {
            _ = try await session.connect()
            let name = database
            let found = try await session.introspection(.schemas(database: name)) { try await $0.schemas(in: name) }
            schemas = found.filter { !$0.isSystem }.map(\.name)
            if !schemas.contains(schema) { schema = schemas.contains("public") ? "public" : schemas.first ?? "" }
            await loadExistingTables()
        } catch {
            loadError = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private func loadExistingTables() async {
        existingTables = []
        guard !useNewDatabase, !(useNewSchema && !isFlat), !effectiveDatabase.isEmpty,
            let session = environment.session(for: targetConnectionID, database: isFlat ? nil : effectiveDatabase)
        else { return }
        let ref = targetRef
        let tables = (try? await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }) ?? []
        existingTables = Set(tables.map(\.name))
    }

    // MARK: - Run

    private func run() {
        var options = DumpOptions.preferred(for: dialect)
        options.content = includeData ? .structureAndData : .structureOnly
        options.includeDrop = replaceExisting
        var names: [String: String] = [:]
        if isSingleTable, let source = request.source.tables?.first?.name, pastedName != source {
            names[source] = pastedName
        }
        let renaming = DumpRenaming(schema: targetRef, tableNames: names)
        let tables: [TableInfo]
        if request.source.tables != nil {
            tables = chosenTables
        } else {
            tables = []
        }
        Task {
            var all = tables
            if request.source.isWholeSchema {
                guard
                    let session = environment.session(
                        for: request.source.connectionID, database: request.source.schema.database)
                else { return }
                let ref = request.source.schema
                all = ((try? await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }) ?? []).filter {
                    $0.kind != .systemTable
                }
            }
            controller.paste(
                request, tables: all, target: targetRef, createDatabase: useNewDatabase, renaming: renaming,
                options: options)
        }
    }
}
