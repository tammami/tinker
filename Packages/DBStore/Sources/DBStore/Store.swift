import DBCore
import Foundation

/// One entry in the query history panel (SPEC §13.2).
public struct QueryHistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var connectionID: UUID
    public var database: String?
    public var sql: String
    public var startedAt: Date
    public var duration: Duration?
    public var rowCount: Int64?
    public var error: String?
    public var succeeded: Bool

    public init(
        id: Int64 = 0,
        connectionID: UUID,
        database: String? = nil,
        sql: String,
        startedAt: Date = Date(),
        duration: Duration? = nil,
        rowCount: Int64? = nil,
        error: String? = nil,
        succeeded: Bool
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.sql = sql
        self.startedAt = startedAt
        self.duration = duration
        self.rowCount = rowCount
        self.error = error
        self.succeeded = succeeded
    }
}

/// What the grid remembers about one table: column widths, sort and filter (SPEC §12.2).
public struct GridPreferences: Sendable, Hashable, Codable {
    public var columnWidths: [String: Double]
    public var sort: [GridSortTerm]
    public var filter: [StoredFilterRule]
    /// Columns the person has hidden for this table, by name.
    public var hiddenColumns: [String]

    public init(
        columnWidths: [String: Double] = [:],
        sort: [GridSortTerm] = [],
        filter: [StoredFilterRule] = [],
        hiddenColumns: [String] = []
    ) {
        self.columnWidths = columnWidths
        self.sort = sort
        self.filter = filter
        self.hiddenColumns = hiddenColumns
    }

    public static let empty = GridPreferences()
    public var isEmpty: Bool { columnWidths.isEmpty && sort.isEmpty && filter.isEmpty && hiddenColumns.isEmpty }
}

/// A persisted sort term. Mirrors `DBSQL.PagePlanner.SortTerm` without `DBStore`
/// depending on `DBSQL`, which the dependency rules forbid.
public struct GridSortTerm: Sendable, Hashable, Codable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// A persisted filter row, stored by operator name so `DBStore` stays independent of `DBSQL`.
public struct StoredFilterRule: Sendable, Hashable, Codable {
    public var column: String
    public var op: String
    public var values: [DBValue]

    public init(column: String, op: String, values: [DBValue]) {
        self.column = column
        self.op = op
        self.values = values
    }
}

/// A saved piece of SQL the editor can insert, with `${1:name}` placeholders.
public struct Snippet: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    public var body: String
    /// `postgresql`, `mysql`, or nil when the snippet suits either engine.
    public var dialect: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64 = 0,
        name: String,
        body: String,
        dialect: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.dialect = dialect
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A sidebar folder and whether the user left it open.
public struct StoredGroup: Sendable, Hashable {
    public var path: [String]
    public var isExpanded: Bool
    public var sortOrder: Int

    public init(path: [String], isExpanded: Bool = true, sortOrder: Int = 0) {
        self.path = path
        self.isExpanded = isExpanded
        self.sortOrder = sortOrder
    }
}

/// Everything the app keeps on disk: connections, groups, query history, grid
/// preferences and settings, in one SQLite file (SPEC §15).
///
/// Secrets are never stored here. They live in the Keychain and configs carry only a
/// ``SecretRef``; `DBStoreTests` greps the file to prove it.
public actor DBStore {
    public let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Rows kept in `query_history` before the oldest are dropped (SPEC §13.2).
    public static let queryHistoryLimit = 10_000

    /// The folder under Application Support, named for the product.
    public static let folderName = "Tinker"
    /// The folder earlier builds used; its contents are adopted the first time this one runs.
    static let legacyFolderName = "DBStudio"

    /// The store's location under Application Support.
    ///
    /// A store left by an earlier build under the old name is moved into place rather than
    /// abandoned, so renaming the product costs nobody their connections.
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path), manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: folder)
        }
        return folder.appendingPathComponent("store.sqlite").path
    }

    public init(path: String = DBStore.defaultPath) async throws {
        database = try SQLiteDatabase(path: path)
        encoder.outputFormatting = [.sortedKeys]
        try await StoreSchema.migrate(database)
    }

    public func close() async {
        await database.close()
    }

    // MARK: - Connections

    /// Every stored connection, in the order the sidebar shows them.
    public func connections() async throws -> [ConnectionConfig] {
        let rows = try await database.query(
            "SELECT json FROM connections ORDER BY sort_order, rowid"
        )
        return try rows.compactMap { row in
            guard let json = row["json"].textValue else { return nil }
            do {
                return try decoder.decode(ConnectionConfig.self, from: Data(json.utf8))
            } catch {
                throw StoreError.decodingFailed("connection: \(error)")
            }
        }
    }

    public func connection(id: UUID) async throws -> ConnectionConfig? {
        let rows = try await database.query(
            "SELECT json FROM connections WHERE id = ?", [.text(id.uuidString)]
        )
        guard let json = rows.first?["json"].textValue else { return nil }
        return try decoder.decode(ConnectionConfig.self, from: Data(json.utf8))
    }

    /// Inserts or replaces a connection. Refuses to write anything but the config itself,
    /// which by construction holds references rather than secrets.
    public func save(_ config: ConnectionConfig, sortOrder: Int? = nil) async throws {
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)
        let order: Int
        if let sortOrder {
            order = sortOrder
        } else {
            let existing = try await database.query(
                "SELECT sort_order FROM connections WHERE id = ?", [.text(config.id.uuidString)]
            )
            if let current = existing.first?["sort_order"].intValue {
                order = Int(current)
            } else {
                let maximum = try await database.query("SELECT COALESCE(MAX(sort_order), -1) FROM connections")
                order = Int(maximum.first?[0].intValue ?? -1) + 1
            }
        }
        try await database.execute(
            """
            INSERT INTO connections (id, json, sort_order, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET json = excluded.json,
                                          sort_order = excluded.sort_order,
                                          updated_at = excluded.updated_at
            """,
            [.text(config.id.uuidString), .text(json), .integer(Int64(order)), .real(Date().timeIntervalSince1970)]
        )
    }

    /// Removes a connection and everything remembered about it. Keychain items are the
    /// caller's to delete, through ``SecretStore/deleteSecrets(forConnection:)``.
    public func deleteConnection(id: UUID) async throws {
        try await database.execute("DELETE FROM connections WHERE id = ?", [.text(id.uuidString)])
        try await database.execute("DELETE FROM grid_prefs WHERE connection_id = ?", [.text(id.uuidString)])
        try await database.execute("DELETE FROM query_history WHERE connection_id = ?", [.text(id.uuidString)])
    }

    /// Writes a new sidebar order in one transaction.
    public func reorderConnections(_ ids: [UUID]) async throws {
        let statements = ids.enumerated().map { offset, id in
            "UPDATE connections SET sort_order = \(offset) WHERE id = '\(id.uuidString)'"
        }
        // UUIDs are generated by the app and contain only hex and dashes, so they cannot
        // carry SQL; every other write in this type uses bound parameters.
        try await database.executeBatch(statements)
    }

    // MARK: - Groups

    public func groups() async throws -> [StoredGroup] {
        let rows = try await database.query("SELECT path, expanded, sort_order FROM groups ORDER BY sort_order, path")
        return rows.compactMap { row in
            guard let path = row["path"].textValue else { return nil }
            return StoredGroup(
                path: path.isEmpty ? [] : path.components(separatedBy: "\u{1F}"),
                isExpanded: (row["expanded"].intValue ?? 1) != 0,
                sortOrder: Int(row["sort_order"].intValue ?? 0)
            )
        }
    }

    public func save(_ group: StoredGroup) async throws {
        try await database.execute(
            """
            INSERT INTO groups (path, expanded, sort_order) VALUES (?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET expanded = excluded.expanded, sort_order = excluded.sort_order
            """,
            [
                .text(group.path.joined(separator: "\u{1F}")),
                .integer(group.isExpanded ? 1 : 0),
                .integer(Int64(group.sortOrder)),
            ]
        )
    }

    public func deleteGroup(path: [String]) async throws {
        try await database.execute(
            "DELETE FROM groups WHERE path = ?", [.text(path.joined(separator: "\u{1F}"))]
        )
    }

    // MARK: - Query history

    /// Records one executed statement and trims the history to its cap.
    @discardableResult
    public func record(_ entry: QueryHistoryEntry) async throws -> Int64 {
        let milliseconds = entry.duration.map {
            Int64($0.components.seconds * 1_000 + $0.components.attoseconds / 1_000_000_000_000_000)
        }
        try await database.execute(
            """
            INSERT INTO query_history
                (connection_id, database, sql, started_at, duration_ms, rows, error, success)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(entry.connectionID.uuidString),
                entry.database.map(SQLiteValue.text) ?? .null,
                .text(entry.sql),
                .real(entry.startedAt.timeIntervalSince1970),
                milliseconds.map(SQLiteValue.integer) ?? .null,
                entry.rowCount.map(SQLiteValue.integer) ?? .null,
                entry.error.map(SQLiteValue.text) ?? .null,
                .integer(entry.succeeded ? 1 : 0),
            ]
        )
        let id = await database.lastInsertRowID
        try await trimHistory()
        return id
    }

    /// Drops the oldest rows once the history passes its cap.
    private func trimHistory() async throws {
        let rows = try await database.query("SELECT COUNT(*) FROM query_history")
        let count = Int(rows.first?[0].intValue ?? 0)
        guard count > Self.queryHistoryLimit else { return }
        try await database.execute(
            """
            DELETE FROM query_history WHERE id IN (
                SELECT id FROM query_history ORDER BY started_at ASC, id ASC LIMIT ?
            )
            """,
            [.integer(Int64(count - Self.queryHistoryLimit))]
        )
    }

    /// The most recent history entries, newest first, optionally filtered.
    public func history(
        connectionID: UUID? = nil,
        matching search: String? = nil,
        limit: Int = 200
    ) async throws -> [QueryHistoryEntry] {
        var sql = """
            SELECT id, connection_id, database, sql, started_at, duration_ms, rows, error, success
            FROM query_history
            """
        var conditions: [String] = []
        var parameters: [SQLiteValue] = []
        if let connectionID {
            conditions.append("connection_id = ?")
            parameters.append(.text(connectionID.uuidString))
        }
        if let search, !search.isEmpty {
            conditions.append("sql LIKE ?")
            parameters.append(.text("%\(search)%"))
        }
        if !conditions.isEmpty { sql += " WHERE \(conditions.joined(separator: " AND "))" }
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?"
        parameters.append(.integer(Int64(limit)))

        return try await database.query(sql, parameters).compactMap { row in
            guard let connectionText = row["connection_id"].textValue,
                  let connectionID = UUID(uuidString: connectionText),
                  let statement = row["sql"].textValue
            else { return nil }
            return QueryHistoryEntry(
                id: row["id"].intValue ?? 0,
                connectionID: connectionID,
                database: row["database"].textValue,
                sql: statement,
                startedAt: Date(timeIntervalSince1970: row["started_at"].doubleValue ?? 0),
                duration: row["duration_ms"].intValue.map { .milliseconds($0) },
                rowCount: row["rows"].intValue,
                error: row["error"].textValue,
                succeeded: (row["success"].intValue ?? 0) != 0
            )
        }
    }

    public func clearHistory() async throws {
        try await database.execute("DELETE FROM query_history")
    }

    public func historyCount() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM query_history").first?[0].intValue ?? 0)
    }

    // MARK: - Snippets

    /// Every snippet, or those for one dialect plus the engine-neutral ones, by name.
    public func snippets(dialect: String? = nil) async throws -> [Snippet] {
        var sql = "SELECT id, name, body, dialect, created_at, updated_at FROM snippets"
        var parameters: [SQLiteValue] = []
        if let dialect {
            sql += " WHERE dialect IS NULL OR dialect = ?"
            parameters.append(.text(dialect))
        }
        sql += " ORDER BY name COLLATE NOCASE, id"
        return try await database.query(sql, parameters).compactMap { row in
            guard let id = row["id"].intValue, let name = row["name"].textValue,
                  let body = row["body"].textValue
            else { return nil }
            return Snippet(
                id: id, name: name, body: body, dialect: row["dialect"].textValue,
                createdAt: Date(timeIntervalSince1970: row["created_at"].doubleValue ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"].doubleValue ?? 0)
            )
        }
    }

    /// Inserts a snippet with id 0, updates one with an id. Returns the id.
    @discardableResult
    public func saveSnippet(_ snippet: Snippet) async throws -> Int64 {
        let now = Date().timeIntervalSince1970
        if snippet.id == 0 {
            try await database.execute(
                "INSERT INTO snippets (name, body, dialect, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [.text(snippet.name), .text(snippet.body), snippet.dialect.map(SQLiteValue.text) ?? .null,
                 .real(now), .real(now)]
            )
            return await database.lastInsertRowID
        }
        try await database.execute(
            "UPDATE snippets SET name = ?, body = ?, dialect = ?, updated_at = ? WHERE id = ?",
            [.text(snippet.name), .text(snippet.body), snippet.dialect.map(SQLiteValue.text) ?? .null,
             .real(now), .integer(snippet.id)]
        )
        return snippet.id
    }

    public func deleteSnippet(id: Int64) async throws {
        try await database.execute("DELETE FROM snippets WHERE id = ?", [.integer(id)])
    }

    // MARK: - Grid preferences

    public func gridPreferences(connectionID: UUID, table: String) async throws -> GridPreferences {
        let rows = try await database.query(
            """
            SELECT column_widths, sort, filter, hidden_columns FROM grid_prefs
            WHERE connection_id = ? AND table_qualified_name = ?
            """,
            [.text(connectionID.uuidString), .text(table)]
        )
        guard let row = rows.first else { return .empty }
        func decode<T: Decodable>(_ column: String, as type: T.Type, default fallback: T) -> T {
            guard let text = row[column].textValue, let data = text.data(using: .utf8) else { return fallback }
            return (try? decoder.decode(T.self, from: data)) ?? fallback
        }
        return GridPreferences(
            columnWidths: decode("column_widths", as: [String: Double].self, default: [:]),
            sort: decode("sort", as: [GridSortTerm].self, default: []),
            filter: decode("filter", as: [StoredFilterRule].self, default: []),
            hiddenColumns: decode("hidden_columns", as: [String].self, default: [])
        )
    }

    public func saveGridPreferences(
        _ preferences: GridPreferences,
        connectionID: UUID,
        table: String
    ) async throws {
        func encodeText<T: Encodable>(_ value: T) throws -> SQLiteValue {
            .text(String(decoding: try encoder.encode(value), as: UTF8.self))
        }
        try await database.execute(
            """
            INSERT INTO grid_prefs (connection_id, table_qualified_name, column_widths, sort, filter, hidden_columns)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(connection_id, table_qualified_name) DO UPDATE SET
                column_widths = excluded.column_widths,
                sort = excluded.sort,
                filter = excluded.filter,
                hidden_columns = excluded.hidden_columns
            """,
            [
                .text(connectionID.uuidString), .text(table),
                try encodeText(preferences.columnWidths),
                try encodeText(preferences.sort),
                try encodeText(preferences.filter),
                try encodeText(preferences.hiddenColumns),
            ]
        )
    }

    // MARK: - Settings

    /// Reads a setting, returning `fallback` when it has never been written.
    public func setting<Value: Codable & Sendable>(
        _ key: String,
        as type: Value.Type = Value.self,
        default fallback: Value
    ) async throws -> Value {
        let rows = try await database.query("SELECT value FROM settings WHERE key = ?", [.text(key)])
        guard let text = rows.first?["value"].textValue, let data = text.data(using: .utf8) else {
            return fallback
        }
        // A setting written by a newer build may not decode; the default is better than a crash.
        return (try? decoder.decode(Value.self, from: data)) ?? fallback
    }

    public func setSetting<Value: Codable & Sendable>(_ value: Value, for key: String) async throws {
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        try await database.execute(
            """
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(json)]
        )
    }

    public func removeSetting(_ key: String) async throws {
        try await database.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
    }
}
