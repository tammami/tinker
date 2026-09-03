import DBCore
import DBSQL
import SwiftUI

/// Compares one table against another and writes the DDL that would align them
/// (SPEC §15b.4).
///
/// It generates and never applies: the script opens in a SQL editor tab, where the user
/// reads it and decides. Destructive statements are held back and listed commented unless
/// the user asks for them.
struct StructureSyncSheet: View {
    let source: TableRef
    let sourceConnectionID: UUID
    let dialect: SQLDialect
    let environment: AppEnvironment
    /// Hands the finished script to the caller, which opens it in a query tab.
    let onGenerate: (UUID, String) -> Void
    let onCancel: () -> Void

    @State private var targetConnectionID: UUID?
    @State private var targetSchema: String = ""
    @State private var targetTable: String = ""
    @State private var includeDestructive = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var summary: String?

    private var connections: [ConnectionConfig] {
        // Only connections of the same dialect: the generator writes one dialect's SQL,
        // and comparing across engines would produce statements neither server accepts.
        environment.connections.filter { $0.dialect == dialect }
    }

    var body: some View {
        SheetFrame(
            title: "Structure Sync",
            icon: Icon.structure,
            subtitle: "Compare \(source.name) against another table and write the DDL that would make that one match. Nothing runs: the script opens in a query tab.",
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section("Source") {
                        LabeledContent("Table", value: source.id)
                    }
                    Section("Target") {
                        Picker("Connection", selection: $targetConnectionID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(connections) { config in
                                Text(config.name).tag(UUID?.some(config.id))
                            }
                        }
                        TextField("Schema", text: $targetSchema)
                        TextField("Table", text: $targetTable)
                    }
                    Section {
                        Toggle("Include statements that discard data", isOn: $includeDestructive)
                    } footer: {
                        Text("Off by default. A drop is listed commented so nothing is lost by running the script.")
                    }
                }
                .formStyle(.grouped)
                .frame(height: 320)

                if let failure {
                    InlineBanner(kind: .error, message: failure) { self.failure = nil }
                }
                if let summary {
                    InlineBanner(kind: .info, message: summary, onDismiss: { self.summary = nil })
                }
            }
        } footer: {
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button {
                Task { await generate() }
            } label: {
                Label(isWorking ? "Comparing…" : "Compare", systemImage: Icon.structure)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || targetConnectionID == nil || targetTable.isEmpty)
        }
        .onAppear {
            targetSchema = source.schema
            targetTable = source.name
            targetConnectionID = connections.first { $0.id != sourceConnectionID }?.id
                ?? connections.first?.id
        }
    }

    private func generate() async {
        guard let targetConnectionID else { return }
        isWorking = true
        failure = nil
        summary = nil
        defer { isWorking = false }

        do {
            let sourceDefinition = try await read(source, on: sourceConnectionID)
            let targetRef = TableRef(
                database: environment.connections.first { $0.id == targetConnectionID }?.database
                    ?? targetSchema,
                schema: targetSchema,
                name: targetTable
            )
            let sync = StructureSync(dialect: dialect)

            let result: StructureSync.Result
            if let targetDefinition = try await readIfPresent(targetRef, on: targetConnectionID) {
                result = sync.compare(source: sourceDefinition, target: targetDefinition)
            } else {
                // The target has no such table, so this is a create rather than a diff.
                result = sync.create(
                    source: sourceDefinition,
                    in: SchemaRef(database: targetRef.database, schema: targetRef.schema)
                )
            }

            let script = result.script(includingDestructive: includeDestructive)
            summary = result.isIdentical
                ? "The target already matches."
                : "\(result.statements.count) statement"
                    + (result.statements.count == 1 ? "" : "s")
                    + (result.destructive.isEmpty
                        ? ""
                        : ", \(result.destructive.count) of them destructive")
            onGenerate(targetConnectionID, script)
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private func read(_ table: TableRef, on connectionID: UUID) async throws -> TableDefinition {
        guard let definition = try await readIfPresent(table, on: connectionID) else {
            throw DBError.protocolError("\(table.id) does not exist")
        }
        return definition
    }

    /// nil when the table is not there, which the caller turns into a create.
    private func readIfPresent(
        _ table: TableRef, on connectionID: UUID
    ) async throws -> TableDefinition? {
        guard let session = environment.session(for: connectionID) else {
            throw DBError.notConnected
        }
        _ = try await session.connect()
        let tables = try await session.introspection(.tables(table.schemaRef)) {
            try await $0.tables(in: table.schemaRef)
        }
        guard let info = tables.first(where: { $0.ref.name == table.name }) else { return nil }
        let ref = info.ref

        let columns = try await session.introspection(.columns(ref)) {
            try await $0.columns(of: ref)
        }
        let primaryKey = try await session.introspection(.primaryKey(ref)) {
            try await $0.primaryKey(of: ref)
        } ?? []
        let indexes = try await session.introspection(.indexes(ref)) {
            try await $0.indexes(of: ref)
        }
        let foreignKeys = try await session.introspection(.foreignKeys(ref)) {
            try await $0.foreignKeys(of: ref)
        }
        let checks = try await session.introspection(.checkConstraints(ref)) {
            try await $0.checkConstraints(of: ref)
        }
        return TableDefinition(
            table: ref,
            info: info,
            columns: columns,
            primaryKey: primaryKey,
            indexes: indexes,
            foreignKeys: foreignKeys,
            checks: checks
        )
    }
}
