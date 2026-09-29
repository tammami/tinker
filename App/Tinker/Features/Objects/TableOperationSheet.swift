import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// The sheet behind Rename, Duplicate, Maintenance and Import Data.
///
/// Each one shows the exact statement before it runs. Rename and duplicate are structure
/// changes and go through the same confirmation as everything else that alters a table.
struct TableOperationSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    /// Called with the table to open afterwards, when there is one.
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    var body: some View {
        switch request.kind {
        case .rename:
            RenameTableSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case .duplicate:
            DuplicateTableSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case let .maintenance(action):
            MaintenanceSheet(
                request: request, action: action, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case .importCSV:
            ImportDataSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        }
    }
}

/// Runs statements on a leased connection and reports what the server said.
@MainActor
private enum OperationRunner {
    static func run(
        _ statements: [String], connectionID: UUID, table: TableRef, environment: AppEnvironment
    ) async throws -> QueryResult? {
        guard let session = environment.session(for: connectionID, table: table) else { throw DBError.notConnected }
        if await session.isReadOnly {
            throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
        }
        _ = try await session.connect()
        let last = try await session.withLease { connection in
            var last: QueryResult?
            for statement in statements {
                last = try await connection.executeCollecting(statement)
            }
            return last
        }
        await session.invalidateIntrospection()
        return last
    }

    static func dialect(_ connectionID: UUID, _ environment: AppEnvironment) -> SQLDialect {
        environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
    }

    static func isProduction(_ connectionID: UUID, _ environment: AppEnvironment) -> Bool {
        environment.connections.first { $0.id == connectionID }?.isProduction ?? false
    }

    /// The connection's name when it is marked production, else nil.
    static func productionName(_ connectionID: UUID, _ environment: AppEnvironment) -> String? {
        let config = environment.connections.first { $0.id == connectionID }
        return config?.isProduction == true ? config?.name : nil
    }
}

// MARK: - Rename

private struct RenameTableSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var failure: String?
    @State private var typedName = ""
    @State private var isRunning = false

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statement: String { TableOperations.rename(request.table, to: name, dialect: dialect) }
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != request.table.name
    }

    var body: some View {
        SheetFrame(
            title: "Rename \(request.table.name)", icon: Icon.rename,
            subtitle: "Views, foreign keys and code that name the table are not updated."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "New name") {
                    TextField("name", text: $name).textFieldStyle(.roundedBorder)
                }
                StatementPreview(sql: statement)
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if let production = OperationRunner.productionName(request.connectionID, environment) {
                ProductionGate(connectionName: production, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Renaming…" : "Rename") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    !isValid || isRunning
                        || !ProductionGate.passes(
                            productionName: OperationRunner.productionName(request.connectionID, environment),
                            requiresTypedName: true, typed: typedName)
                )
        }
        .onAppear { name = request.table.name }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await OperationRunner.run(
                [statement], connectionID: request.connectionID, table: request.table, environment: environment)
            onFinished(
                TableRef(
                    database: request.table.database, schema: request.table.schema,
                    name: name.trimmingCharacters(in: .whitespaces)))
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Duplicate

private struct DuplicateTableSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var includeData = false
    @State private var failure: String?
    @State private var typedName = ""
    @State private var isRunning = false

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statements: [String] {
        TableOperations.duplicate(request.table, to: name, includeData: includeData, dialect: dialect)
    }
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != request.table.name
    }

    var body: some View {
        SheetFrame(
            title: "Duplicate \(request.table.name)", icon: Icon.duplicate,
            subtitle: "Copies the columns, defaults, constraints and indexes. Foreign keys are not copied."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "New table") {
                    TextField("name", text: $name).textFieldStyle(.roundedBorder)
                }
                FieldRow(label: "") {
                    Toggle("Copy the rows as well", isOn: $includeData)
                }
                StatementPreview(sql: statements.joined(separator: ";\n") + ";")
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if let production = OperationRunner.productionName(request.connectionID, environment) {
                ProductionGate(connectionName: production, requiresTypedName: true, typed: $typedName)
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Duplicating…" : "Duplicate") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    !isValid || isRunning
                        || !ProductionGate.passes(
                            productionName: OperationRunner.productionName(request.connectionID, environment),
                            requiresTypedName: true, typed: typedName)
                )
        }
        .onAppear { name = request.table.name + "_copy" }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await OperationRunner.run(
                statements, connectionID: request.connectionID, table: request.table, environment: environment)
            onFinished(
                TableRef(
                    database: request.table.database, schema: request.table.schema,
                    name: name.trimmingCharacters(in: .whitespaces)))
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Maintenance

private struct MaintenanceSheet: View {
    let request: TableOperationRequest
    let action: MaintenanceAction
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var failure: String?
    @State private var typedName = ""
    @State private var isRunning = false
    @State private var output: QueryResult?
    @State private var elapsed: Duration?

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statement: String? { TableOperations.maintenance(action, on: request.table, dialect: dialect) }

    var body: some View {
        SheetFrame(title: "\(action.title) \(request.table.name)", icon: Icon.maintenance, subtitle: action.summary) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let statement {
                    StatementPreview(sql: statement)
                } else {
                    InlineBanner(
                        kind: .warning, message: "This engine has no \(action.title.lowercased()) for tables.",
                        onDismiss: {})
                }
                if let output, !output.rows.isEmpty {
                    SimpleTable(
                        columns: output.columns.map { SimpleTable.Column(title: $0.name, width: 140) },
                        rows: output.rows.map { row in row.map { ClipboardFormatter.cellText($0, nullText: "NULL") } }
                    )
                    .frame(height: 120)
                } else if let elapsed {
                    InlineBanner(
                        kind: .success, message: "Done in \(QueryTabController.format(elapsed))", onDismiss: {})
                }
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if let production = OperationRunner.productionName(request.connectionID, environment) {
                ProductionGate(connectionName: production, requiresTypedName: false, typed: .constant(""))
            }
            Spacer()
            Button(elapsed == nil ? "Cancel" : "Close", action: onCancel).keyboardShortcut(.cancelAction)
            if elapsed == nil {
                Button(isRunning ? "Running…" : "Run") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(statement == nil || isRunning)
            }
        }
    }

    private func run() async {
        guard let statement else { return }
        isRunning = true
        defer { isRunning = false }
        let start = ContinuousClock.now
        do {
            output = try await OperationRunner.run(
                [statement], connectionID: request.connectionID, table: request.table, environment: environment)
            elapsed = start.duration(to: .now)
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

/// The statement a sheet is about to run, shown as it will be sent.
struct StatementPreview: View {
    let sql: String
    var label = "Statement"
    var maxHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.sm)
            }
            .frame(maxHeight: maxHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius).strokeBorder(
                    Color.primary.opacity(0.1)))
        }
    }
}
