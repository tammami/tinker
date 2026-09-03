import DBCore
import DBGrid
import DBSQL
import Foundation
import Observation

/// Drives the Structure tab: what the server has, what the user is editing, and the
/// difference between them (SPEC §15b).
///
/// It never mutates anything as the user types. The edit lives here beside the loaded
/// definition, and only Execute — reached through the preview — sends anything.
@MainActor
@Observable
public final class StructureController {
    public let table: TableRef
    public let connectionID: UUID
    public let dialect: SQLDialect

    /// What introspection read. Replaced wholesale after every successful run.
    public private(set) var loaded: TableDefinition?
    /// What the user is editing. Equal to `loaded` until they change something.
    public var edited: TableDefinition?

    public private(set) var isLoading = false
    public private(set) var errorText: String?
    /// Set after a run so the user sees what happened without opening the preview again.
    public private(set) var statusText: String?
    /// Structure is read-only until this is turned on, so browsing cannot alter anything.
    public var isEditing = false
    /// The collations the column editor offers.
    public private(set) var collations: [CollationInfo] = []

    private let environment: AppEnvironment

    public init(
        table: TableRef,
        connectionID: UUID,
        dialect: SQLDialect,
        environment: AppEnvironment
    ) {
        self.table = table
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    private var session: ConnectionSession? { environment.session(for: connectionID) }

    // MARK: - Loading

    public func load() async {
        guard let session else {
            errorText = "No session for this connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await session.connect()
            let info = try await session.introspection(.tables(table.schemaRef)) {
                try await $0.tables(in: table.schemaRef)
            }.first { $0.ref == table }
            let columns = try await session.introspection(.columns(table)) {
                try await $0.columns(of: table)
            }
            let primaryKey = try await session.introspection(.primaryKey(table)) {
                try await $0.primaryKey(of: table)
            } ?? []
            let indexes = try await session.introspection(.indexes(table)) {
                try await $0.indexes(of: table)
            }
            let foreignKeys = try await session.introspection(.foreignKeys(table)) {
                try await $0.foreignKeys(of: table)
            }
            let checks = try await session.introspection(.checkConstraints(table)) {
                try await $0.checkConstraints(of: table)
            }
            let triggers = try await session.introspection(.triggers(table)) {
                try await $0.triggers(of: table)
            }
            let partitioning = try await session.introspection(.partitioning(table)) {
                try await $0.partitioning(of: table)
            }

            let definition = TableDefinition(
                table: table,
                info: info,
                columns: columns,
                primaryKey: primaryKey,
                indexes: indexes,
                foreignKeys: foreignKeys,
                checks: checks,
                triggers: triggers,
                partitioning: partitioning
            )
            loaded = definition
            edited = definition
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Loaded lazily: the picker needs them, the rest of the tab does not.
    public func loadCollationsIfNeeded() async {
        guard collations.isEmpty, let session else { return }
        collations = (try? await session.introspection(.collations(database: table.database)) {
            try await $0.collations(in: table.database)
        }) ?? []
    }

    // MARK: - The pending change

    /// The statements that would take the server to what the user has edited.
    public var pendingStatements: [GeneratedDDL] {
        guard let loaded, let edited else { return [] }
        return DDLGenerator(dialect: dialect).alter(from: loaded, to: edited)
    }

    public var hasPendingChanges: Bool { !pendingStatements.isEmpty }

    /// True when the engine undoes a failed run. MySQL does not, and the preview says so.
    public var isTransactional: Bool { dialect == .postgresql }

    public func discardChanges() {
        edited = loaded
        statusText = nil
    }

    // MARK: - Executing

    /// Runs the pending statements and reloads from the server.
    ///
    /// What the tab shows afterwards is what the server has, never what was asked for: the
    /// introspection cache for this table is dropped first, so a partly-applied MySQL run
    /// is visible rather than hidden behind the edit that produced it.
    public func execute() async {
        guard let session, !pendingStatements.isEmpty else { return }
        if await session.isReadOnly {
            errorText = "This connection is read-only"
            return
        }
        let statements = pendingStatements
        isLoading = true
        defer { isLoading = false }

        let executor = DDLExecutor(session: session, dialect: dialect)
        do {
            let result = try await executor.run(statements)
            await session.invalidateIntrospection()
            await load()

            if result.isSuccess {
                errorText = nil
                statusText = "Applied \(result.applied.count) statement"
                    + (result.applied.count == 1 ? "" : "s")
            } else {
                statusText = nil
                errorText = failureText(result)
            }
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            await session.invalidateIntrospection()
            await load()
            errorText = message
        }
    }

    /// The server's message, plus what it left behind when the engine could not undo it.
    private func failureText(_ result: DDLExecutionResult) -> String {
        var text = result.errorText ?? "The statement failed"
        if let failed = result.failed {
            text += "\n\nFailed statement:\n\(failed.sql)"
        }
        if result.didRollBack {
            text += "\n\nNothing was changed: the transaction was rolled back."
        } else if !result.applied.isEmpty {
            let applied = result.applied.map { "  \($0.sql)" }.joined(separator: "\n")
            text += "\n\nMySQL commits each structure statement as it runs, so these had "
                + "already taken effect and were not undone:\n\(applied)"
        }
        return text
    }

    public func clearError() { errorText = nil }
    public func clearStatus() { statusText = nil }
}
