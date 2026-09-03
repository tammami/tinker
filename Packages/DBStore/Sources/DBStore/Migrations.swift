import Foundation

/// One numbered schema change. Migrations are applied in order and the highest applied
/// number is recorded in `PRAGMA user_version` (SPEC §15).
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let statements: [String]

    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

/// The store's schema history. Append new migrations; never edit a released one.
public enum StoreSchema {
    public static let migrations: [Migration] = [
        Migration(version: 1, name: "initial", statements: [
            """
            CREATE TABLE connections (
                id          TEXT PRIMARY KEY,
                json        TEXT NOT NULL,
                sort_order  INTEGER NOT NULL DEFAULT 0,
                updated_at  REAL NOT NULL
            )
            """,
            """
            CREATE TABLE groups (
                path        TEXT PRIMARY KEY,
                expanded    INTEGER NOT NULL DEFAULT 1,
                sort_order  INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE query_history (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                connection_id TEXT NOT NULL,
                database      TEXT,
                sql           TEXT NOT NULL,
                started_at    REAL NOT NULL,
                duration_ms   INTEGER,
                rows          INTEGER,
                error         TEXT,
                success       INTEGER NOT NULL
            )
            """,
            "CREATE INDEX query_history_started_idx ON query_history (started_at DESC)",
            "CREATE INDEX query_history_connection_idx ON query_history (connection_id, started_at DESC)",
            """
            CREATE TABLE grid_prefs (
                connection_id        TEXT NOT NULL,
                table_qualified_name TEXT NOT NULL,
                column_widths        TEXT,
                sort                 TEXT,
                filter               TEXT,
                PRIMARY KEY (connection_id, table_qualified_name)
            )
            """,
            """
            CREATE TABLE settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """,
        ]),
    ]

    /// Applies every migration the database has not seen yet.
    ///
    /// Each migration runs in its own transaction, so a failure leaves the database at the
    /// last version that fully applied rather than half-changed.
    @discardableResult
    public static func migrate(_ database: SQLiteDatabase) async throws -> Int {
        var current = try await database.userVersion
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            do {
                try await database.executeBatch(migration.statements)
                try await database.setUserVersion(migration.version)
                current = migration.version
            } catch {
                throw StoreError.migrationFailed(
                    version: migration.version, message: String(describing: error)
                )
            }
        }
        return current
    }

    /// The version this build expects a store to be at.
    public static var latestVersion: Int {
        migrations.map(\.version).max() ?? 0
    }
}
