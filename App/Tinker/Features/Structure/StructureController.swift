import DBCore
import DBGrid
import DBSQL
import Foundation
import Logging
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
    /// The collations the column editor offers. Read only when the detail panel asks.
    public private(set) var collations: [CollationInfo] = []
    /// The column the detail panel shows and the arrow keys move between.
    public var selectedColumnID: UUID?
    /// The enum member editor, opened from the detail panel's "…" button.
    public var isEnumEditorPresented = false
    /// How long the last catalog read took, for the smoke test and the log.
    public private(set) var lastLoadDuration: Duration?
    /// The read in flight, so a second caller waits for it instead of starting another.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(label: "tinker.structure")
    /// Set once a `.create` tab has actually built its table, so the caller can close the
    /// sheet and open the table for real.
    public private(set) var didCreate = false

    /// Whether the tab is changing a table that exists or building one that does not
    /// (SPEC §15b.3). A new table has nothing to diff against, so it emits `CREATE`.
    public enum Mode: Sendable, Hashable {
        case edit
        case create
    }

    public let mode: Mode
    private let environment: AppEnvironment

    public init(
        table: TableRef,
        connectionID: UUID,
        dialect: SQLDialect,
        environment: AppEnvironment,
        mode: Mode = .edit
    ) {
        self.table = table
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
        self.mode = mode
        if mode == .create {
            // A new table starts as one empty column, editable straight away: an editor
            // that opens locked would have to be unlocked before anything could be typed.
            let blank = TableDefinition(
                ref: table,
                columns: [
                    ColumnDefinition(
                        name: "id",
                        type: dialect == .mysql ? "int" : "integer",
                        isNullable: false,
                        isAutoIncrement: true
                    )
                ],
                primaryKey: ["id"]
            )
            loaded = TableDefinition(ref: table)
            edited = blank
            isEditing = true
        }
    }

    private var session: ConnectionSession? { environment.session(for: connectionID, table: table) }

    /// True while the user has changed something that has not been run.
    public var hasUnsavedEdits: Bool {
        guard let loaded, let edited else { return false }
        return loaded != edited
    }

    // MARK: - Loading

    /// Reads the table's definition, once.
    ///
    /// The table tab starts this read as soon as its rows are on screen, and the Structure
    /// view asks again when it appears; the second caller waits for the read in flight
    /// rather than starting its own, so the switch costs nothing extra.
    ///
    /// `force` reads again from the server, dropping this table's cached catalogue first,
    /// and waits for any read already in flight rather than racing it. Edits the user
    /// has not run are kept when `keepingEdits` is set — a refresh must not throw away
    /// their work — and replaced otherwise, which is what a run wants.
    public func load(force: Bool = false, keepingEdits: Bool = false) async {
        // Nothing to read: the table does not exist yet.
        guard mode == .edit else { return }
        if let loadTask {
            await loadTask.value
            if !force { return }
        }
        // Already read: switching back to Structure shows it at once rather than re-reading.
        if loaded != nil, !force { return }
        if force, let session {
            await session.invalidateIntrospection(for: table)
        }
        let task = Task { await read(keepingEdits: keepingEdits) }
        loadTask = task
        isLoading = true
        await task.value
        if loadTask == task {
            loadTask = nil
            isLoading = false
        }
    }

    /// One leased connection, the catalog reads one after another on it.
    ///
    /// Reads fired together each miss the cache at once, and on a fresh session every
    /// miss leases — and opens — its own connection; seven handshakes cost more than
    /// seven small queries in a row on one.
    private func read(keepingEdits: Bool) async {
        guard let session else {
            errorText = "No session for this connection"
            return
        }
        let started = ContinuousClock.now
        do {
            let table = table
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }

            let columns = try await session.introspection(.columns(table), on: connection) {
                try await $0.columns(of: table)
            }
            let primaryKey =
                try await session.introspection(.primaryKey(table), on: connection) {
                    try await $0.primaryKey(of: table)
                } ?? []
            let indexes = try await session.introspection(.indexes(table), on: connection) {
                try await $0.indexes(of: table)
            }
            let foreignKeys = try await session.introspection(.foreignKeys(table), on: connection) {
                try await $0.foreignKeys(of: table)
            }
            let checks = try await session.introspection(.checkConstraints(table), on: connection) {
                try await $0.checkConstraints(of: table)
            }
            let triggers = try await session.introspection(.triggers(table), on: connection) {
                try await $0.triggers(of: table)
            }
            let partitioning = try await session.introspection(.partitioning(table), on: connection) {
                try await $0.partitioning(of: table)
            }
            // The sidebar has usually listed the schema already; if not, one row is read,
            // never the size of every table in it.
            let listed: [TableInfo]? = await session.cachedIntrospection(.tables(table.schemaRef))
            var info = listed?.first { $0.ref == table }
            if info == nil {
                info = try await session.introspection(.tableInfo(table), on: connection) {
                    try await $0.tableInfo(of: table)
                }
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
                partitioning: partitioning,
                options: TableOptions(engine: info?.engine, collation: info?.collation)
            )
            // Column identities are fresh every read; the selection follows the name.
            let selectedName = edited?.columns.first { $0.id == selectedColumnID }?.name
            let keptEdits = keepingEdits && hasUnsavedEdits ? edited : nil
            // Said only when the server's definition actually moved: the table tab reloads
            // its grid whenever this text changes, and a re-read that found nothing new
            // must not set that off.
            let serverChanged = loaded != nil && loaded != definition
            loaded = definition
            if let keptEdits {
                edited = keptEdits
                if serverChanged {
                    statusText = "The table changed on the server; your unsaved edits are kept."
                }
            } else {
                edited = definition
            }
            errorText = nil
            let columnsShown = edited?.columns ?? definition.columns
            if let selectedName, let match = columnsShown.first(where: { $0.name == selectedName }) {
                selectedColumnID = match.id
            } else if !columnsShown.contains(where: { $0.id == selectedColumnID }) {
                selectedColumnID = columnsShown.first?.id
            }
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
        let duration = started.duration(to: .now)
        lastLoadDuration = duration
        logger.info("structure read", metadata: ["table": "\(table.name)", "took": "\(duration)"])
    }

    /// Loaded lazily: the detail panel's pickers need them, the rest of the tab does not.
    public func loadCollationsIfNeeded() async {
        guard collations.isEmpty, let session else { return }
        collations =
            (try? await session.introspection(.collations(database: table.database)) {
                try await $0.collations(in: table.database)
            }) ?? []
    }

    /// MySQL groups collations under character sets; the panel offers those sets.
    public var characterSets: [String] {
        var seen = Set<String>()
        return collations.compactMap { collation in
            guard let set = collation.characterSet, seen.insert(set).inserted else { return nil }
            return set
        }
    }

    /// The column the detail panel is showing, in the edited definition.
    public var selectedColumnIndex: Int? {
        guard let selectedColumnID else { return nil }
        return edited?.columns.firstIndex { $0.id == selectedColumnID }
    }

    /// Moves the selection by `offset` rows, staying inside the list.
    public func moveSelection(by offset: Int) {
        guard let columns = edited?.columns, !columns.isEmpty else { return }
        let current = selectedColumnIndex ?? (offset > 0 ? -1 : columns.count)
        let next = min(max(current + offset, 0), columns.count - 1)
        selectedColumnID = columns[next].id
    }

    // MARK: - The pending change

    /// The statements that would take the server to what the user has edited.
    public var pendingStatements: [GeneratedDDL] {
        guard let edited else { return [] }
        let generator = DDLGenerator(dialect: dialect)
        switch mode {
        case .create:
            return edited.columns.isEmpty ? [] : generator.create(edited)
        case .edit:
            guard let loaded else { return [] }
            return generator.alter(from: loaded, to: edited)
        }
    }

    public var hasPendingChanges: Bool { !pendingStatements.isEmpty }

    /// True when the engine undoes a failed run. MySQL does not, and the preview says so.
    public var isTransactional: Bool { dialect != .mysql }

    public func discardChanges() {
        edited = loaded
        statusText = nil
    }

    // MARK: - Executing

    /// Runs the pending statements and reloads from the server.
    ///
    /// What the tab shows afterwards is what the server has, never what was asked for: the
    /// introspection cache for this table is dropped and the definition read again, on
    /// success and on failure alike, so a partly-applied MySQL run is visible rather than
    /// hidden behind the edit that produced it.
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
            if mode == .create, result.isSuccess {
                // The table exists from here on, so the tab stops being a builder and
                // starts reflecting the server like any other.
                didCreate = true
            }
            await load(force: true)

            if result.isSuccess {
                errorText = nil
                statusText =
                    "Applied \(result.applied.count) statement"
                    + (result.applied.count == 1 ? "" : "s")
            } else {
                statusText = nil
                errorText = failureText(result)
            }
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            await session.invalidateIntrospection()
            await load(force: true)
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
            text +=
                "\n\nMySQL commits each structure statement as it runs, so these had "
                + "already taken effect and were not undone:\n\(applied)"
        }
        return text
    }

    public func clearError() { errorText = nil }
    public func clearStatus() { statusText = nil }
}
