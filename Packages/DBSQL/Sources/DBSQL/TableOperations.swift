import DBCore
import Foundation

/// The housekeeping statements each engine offers for a table.
///
/// Only actions that are safe to run from a client are listed: nothing here rewrites
/// data, and `VACUUM FULL` is left out because it takes an exclusive lock for as long as
/// the table is large.
public enum MaintenanceAction: String, Sendable, Hashable, CaseIterable, Codable {
    case analyze
    case vacuum
    case reindex
    case optimize
    case check

    /// The actions an engine understands, in the order a menu lists them.
    public static func available(for dialect: SQLDialect) -> [MaintenanceAction] {
        switch dialect {
        case .postgresql: [.analyze, .vacuum, .reindex]
        case .mysql: [.analyze, .optimize, .check]
        // SQLite's VACUUM works on the whole file, and REINDEX on a table's indexes.
        case .sqlite: [.analyze, .vacuum, .reindex]
        }
    }

    public var title: String {
        switch self {
        case .analyze: "Analyze"
        case .vacuum: "Vacuum"
        case .reindex: "Reindex"
        case .optimize: "Optimize"
        case .check: "Check"
        }
    }

    /// One line on what the statement does, for the confirmation sheet.
    public var summary: String {
        switch self {
        case .analyze: "Refreshes the planner's statistics for the table."
        case .vacuum: "Reclaims space left by updated and deleted rows. On SQLite this rebuilds the whole file."
        case .reindex: "Rebuilds every index on the table."
        case .optimize: "Reorganises the table's storage and refreshes its statistics."
        case .check: "Checks the table for errors and reports what it finds."
        }
    }

    /// Whether the statement returns a result set worth showing.
    public var returnsRows: Bool { self == .check || self == .optimize }
}

/// Generates the statements behind Rename, Duplicate and Maintenance.
///
/// Identifiers are quoted per dialect; nothing user-typed is interpolated unquoted.
public enum TableOperations {
    /// `ALTER TABLE … RENAME TO` on PostgreSQL and SQLite, `RENAME TABLE` on MySQL.
    public static func rename(_ table: TableRef, to newName: String, dialect: SQLDialect) -> String {
        let source = Identifier.qualified(table, dialect: dialect)
        switch dialect {
        case .postgresql, .sqlite:
            return "ALTER TABLE \(source) RENAME TO \(Identifier.quote(newName, dialect: dialect))"
        case .mysql:
            let target = Identifier.qualified(
                TableRef(database: table.database, schema: table.schema, name: newName), dialect: dialect
            )
            return "RENAME TABLE \(source) TO \(target)"
        }
    }

    /// Copies a table's definition, and optionally its rows, under a new name.
    ///
    /// PostgreSQL's `LIKE … INCLUDING ALL` carries defaults, constraints, indexes and
    /// comments; MySQL's `CREATE TABLE … LIKE` does the same. Neither copies foreign keys,
    /// which is what a person duplicating a table for an experiment wants. SQLite has no
    /// such form: `CREATE TABLE … AS SELECT` copies the column names and affinities and
    /// nothing else, and the statement says so in a comment.
    public static func duplicate(
        _ table: TableRef, to newName: String, includeData: Bool, dialect: SQLDialect
    ) -> [String] {
        let source = Identifier.qualified(table, dialect: dialect)
        let target = Identifier.qualified(
            TableRef(database: table.database, schema: table.schema, name: newName), dialect: dialect
        )
        var statements: [String] = []
        switch dialect {
        case .postgresql:
            statements.append("CREATE TABLE \(target) (LIKE \(source) INCLUDING ALL)")
        case .mysql:
            statements.append("CREATE TABLE \(target) LIKE \(source)")
        case .sqlite:
            statements.append(
                "-- SQLite copies columns only: keys, indexes and constraints are not carried over\n"
                    + "CREATE TABLE \(target) AS SELECT * FROM \(source) WHERE 0")
        }
        if includeData {
            statements.append("INSERT INTO \(target) SELECT * FROM \(source)")
        }
        return statements
    }

    /// The maintenance statement for one table, or nil when the engine has no such action.
    public static func maintenance(
        _ action: MaintenanceAction, on table: TableRef, dialect: SQLDialect
    ) -> String? {
        let name = Identifier.qualified(table, dialect: dialect)
        switch (dialect, action) {
        case (.postgresql, .analyze): return "ANALYZE \(name)"
        case (.postgresql, .vacuum): return "VACUUM (ANALYZE) \(name)"
        case (.postgresql, .reindex): return "REINDEX TABLE \(name)"
        case (.mysql, .analyze): return "ANALYZE TABLE \(name)"
        case (.mysql, .optimize): return "OPTIMIZE TABLE \(name)"
        case (.mysql, .check): return "CHECK TABLE \(name)"
        case (.sqlite, .analyze): return "ANALYZE \(name)"
        // VACUUM takes a schema name, not a table: it rewrites the whole database file.
        case (.sqlite, .vacuum): return "VACUUM"
        case (.sqlite, .reindex): return "REINDEX \(name)"
        default: return nil
        }
    }

    /// `EXPLAIN` for a statement, in the engine's own spelling.
    ///
    /// `ANALYZE` actually runs the statement, so it is only offered for reads and the
    /// caller decides; the plain plan never touches data.
    public static func explain(_ statement: String, analyze: Bool, dialect: SQLDialect) -> String {
        let body = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        switch dialect {
        case .postgresql:
            return analyze
                ? "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(body)"
                : "EXPLAIN (FORMAT TEXT) \(body)"
        case .mysql:
            return analyze ? "EXPLAIN ANALYZE \(body)" : "EXPLAIN \(body)"
        case .sqlite:
            // SQLite has no ANALYZE form; the query plan is the only explanation it gives.
            return "EXPLAIN QUERY PLAN \(body)"
        }
    }
}
