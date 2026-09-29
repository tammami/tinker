import DBCore
import DBSQL
import SwiftUI

/// New Database… on a connection and Drop Database… on a database.
///
/// Both show the exact statement before it runs, refuse on a read-only connection, and
/// go through the production gate. Dropping always asks for the database's name to be
/// typed: it removes every table in it at once, on any server.
struct DatabaseOperationSheet: View {
    let request: DatabaseOperationRequest
    let environment: AppEnvironment
    /// For a drop: the tabs on that database, and how many hold unsaved work.
    var affectedTabs: (total: Int, unsaved: Int) = (0, 0)
    let onFinished: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch request.kind {
        case .create:
            CreateDatabaseSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case let .drop(name):
            DropDatabaseSheet(
                request: request, name: name, environment: environment, affectedTabs: affectedTabs,
                onFinished: onFinished, onCancel: onCancel)
        }
    }
}

@MainActor
private enum DatabaseRunner {
    static func config(_ request: DatabaseOperationRequest, _ environment: AppEnvironment) -> ConnectionConfig? {
        environment.connections.first { $0.id == request.connectionID }
    }

    /// Runs one statement on the connection's main session. `CREATE`/`DROP DATABASE`
    /// cannot run inside a transaction on PostgreSQL, and a leased connection runs it
    /// on its own.
    static func run(_ statement: String, _ request: DatabaseOperationRequest, _ environment: AppEnvironment)
        async throws
    {
        guard let session = environment.session(for: request.connectionID) else { throw DBError.notConnected }
        if await session.isReadOnly {
            throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
        }
        _ = try await session.connect()
        try await session.withLease { _ = try await $0.executeCollecting(statement) }
        await session.invalidateIntrospection()
    }

    static func rows(_ sql: String, _ request: DatabaseOperationRequest, _ environment: AppEnvironment) async
        -> [[String]]
    {
        guard let session = environment.session(for: request.connectionID) else { return [] }
        do {
            _ = try await session.connect()
            let result = try await session.withLease { try await $0.executeCollecting(sql) }
            return result.rows.map { $0.map { $0.text ?? "" } }
        } catch {
            return []
        }
    }
}

// MARK: - Create

private struct CreateDatabaseSheet: View {
    let request: DatabaseOperationRequest
    let environment: AppEnvironment
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var options = DatabaseOperations.CreateOptions()
    @State private var characterSets: [String] = []
    /// Collation → its character set, so the list follows the chosen set.
    @State private var collations: [(name: String, set: String)] = []
    @State private var failure: String?
    @State private var typedName = ""
    @State private var isRunning = false

    private var config: ConnectionConfig? { DatabaseRunner.config(request, environment) }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var statement: String { DatabaseOperations.create(trimmed.isEmpty ? "name" : trimmed, dialect: dialect, options: options) ?? "" }
    private var productionName: String? { config?.isProduction == true ? config?.name : nil }

    private static let encodings = ["UTF8", "LATIN1", "LATIN2", "WIN1252", "SQL_ASCII", "EUC_JP", "EUC_KR", "EUC_CN"]

    var body: some View {
        SheetFrame(
            title: "New Database", icon: Icon.database,
            subtitle: "On \(config?.name ?? "the server"). Leave a field empty to take the server's default."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "Name") {
                    TextField("database_name", text: $name).textFieldStyle(.roundedBorder)
                }
                switch dialect {
                case .postgresql:
                    FieldRow(label: "Encoding") {
                        Picker("Encoding", selection: $options.encoding) {
                            Text("Server default").tag("")
                            ForEach(Self.encodings, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    FieldRow(label: "Owner") {
                        TextField("the connection's user", text: $options.owner).textFieldStyle(.roundedBorder)
                    }
                    FieldRow(label: "Template") {
                        Picker("Template", selection: $options.template) {
                            Text(options.encoding.isEmpty ? "Default (template1)" : "template0").tag("")
                            Text("template0").tag("template0")
                            Text("template1").tag("template1")
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                case .mysql:
                    FieldRow(label: "Character set") {
                        Picker("Character set", selection: $options.characterSet) {
                            Text("Server default").tag("")
                            ForEach(characterSets, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: options.characterSet) { _, _ in options.collation = "" }
                    }
                    FieldRow(label: "Collation") {
                        Picker("Collation", selection: $options.collation) {
                            Text("Default for the set").tag("")
                            ForEach(collations.filter { $0.set == options.characterSet }.map(\.name), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .disabled(options.characterSet.isEmpty)
                    }
                case .sqlite:
                    Label("A SQLite database is a file: use New Connection › SQLite › New… instead.", systemImage: Icon.info)
                        .font(.callout).foregroundStyle(.secondary)
                }
                StatementPreview(sql: statement)
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if let productionName {
                ProductionGate(connectionName: productionName, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Creating…" : "Create") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    trimmed.isEmpty || isRunning || dialect == .sqlite
                        || !ProductionGate.passes(productionName: productionName, requiresTypedName: true, typed: typedName)
                )
        }
        .task { await loadCharacterSets() }
    }

    private func loadCharacterSets() async {
        guard dialect == .mysql else { return }
        let sets = await DatabaseRunner.rows("SHOW CHARACTER SET", request, environment)
        characterSets = sets.compactMap(\.first).sorted()
        let all = await DatabaseRunner.rows("SHOW COLLATION", request, environment)
        collations = all.compactMap { $0.count > 1 ? ($0[0], $0[1]) : nil }.sorted { $0.name < $1.name }
        if characterSets.contains("utf8mb4") { options.characterSet = "utf8mb4" }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            guard let sql = DatabaseOperations.create(trimmed, dialect: dialect, options: options) else {
                failure = "The character set or collation is not a name the server can take."
                return
            }
            try await DatabaseRunner.run(sql, request, environment)
            onFinished()
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Drop

private struct DropDatabaseSheet: View {
    let request: DatabaseOperationRequest
    let name: String
    let environment: AppEnvironment
    let affectedTabs: (total: Int, unsaved: Int)
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var typed = ""
    @State private var force = false
    /// Required when tabs on the database hold work that dropping it throws away.
    @State private var acceptsLoss = false
    @State private var failure: String?
    @State private var isRunning = false

    private var config: ConnectionConfig? { DatabaseRunner.config(request, environment) }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }
    private var statement: String { DatabaseOperations.drop(name, dialect: dialect, force: force) ?? "" }

    var body: some View {
        SheetFrame(
            title: "Drop “\(name)”?", icon: Icon.delete,
            subtitle: "Every table, view and routine in it is deleted. This cannot be undone."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if config?.isProduction == true {
                    Label("\(config?.name ?? "This connection") is a production server.", systemImage: Icon.warning)
                        .font(.callout.weight(.semibold)).foregroundStyle(.red)
                }
                if dialect == .postgresql {
                    Toggle("End other sessions on it first (WITH FORCE, PostgreSQL 13+)", isOn: $force)
                }
                if affectedTabs.total > 0 {
                    Label(
                        "\(affectedTabs.total) open tab\(affectedTabs.total == 1 ? "" : "s") on this database will be closed.",
                        systemImage: Icon.info
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if affectedTabs.unsaved > 0 {
                    Toggle(
                        "\(affectedTabs.unsaved) of them \(affectedTabs.unsaved == 1 ? "has" : "have") uncommitted changes or an open transaction; lose them",
                        isOn: $acceptsLoss)
                }
                FieldRow(label: "Type the name") {
                    TextField(name, text: $typed).textFieldStyle(.roundedBorder)
                }
                StatementPreview(sql: statement)
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Dropping…" : "Drop Database", role: .destructive) { Task { await run() } }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(typed != name || isRunning || (affectedTabs.unsaved > 0 && !acceptsLoss))
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            // Read-only is checked before anything is closed: a refused drop leaves every
            // tab and its transaction as they were.
            guard let session = environment.session(for: request.connectionID) else { throw DBError.notConnected }
            if await session.isReadOnly {
                throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
            }
            // Tinker's own session on that database would hold the drop up on PostgreSQL.
            await environment.closeSession(for: request.connectionID, database: name)
            try await DatabaseRunner.run(statement, request, environment)
            onFinished()
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}
