import DBCore
import Foundation

/// A statement the app generated, with its values kept out of the SQL text.
///
/// Values always travel as bound parameters. ``displaySQL`` renders them inline for the
/// commit preview sheet and never for execution (SPEC §7.1, §12.3).
public struct GeneratedStatement: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case insert, update, delete
    }

    public let kind: Kind
    public let sql: String
    public let parameters: [DBValue]
    public let table: TableRef
    /// True when the statement must affect exactly one row, which the commit flow verifies.
    public let expectsSingleRow: Bool
    public let id: UUID

    public init(
        kind: Kind,
        sql: String,
        parameters: [DBValue],
        table: TableRef,
        expectsSingleRow: Bool,
        id: UUID = UUID()
    ) {
        self.kind = kind
        self.sql = sql
        self.parameters = parameters
        self.table = table
        self.expectsSingleRow = expectsSingleRow
        self.id = id
    }

    /// The statement with its parameters substituted as literals. Display only.
    public func displaySQL(dialect: SQLDialect) -> String {
        SQLLiteral.renderForDisplay(sql, parameters: parameters, dialect: dialect)
    }
}

/// Collects bound parameters and hands out the matching placeholders.
struct ParameterList {
    let dialect: SQLDialect
    private(set) var values: [DBValue] = []

    init(dialect: SQLDialect) { self.dialect = dialect }

    /// Appends `value` and returns the placeholder that refers to it.
    mutating func bind(_ value: DBValue) -> String {
        values.append(value)
        return SQLLiteral.placeholder(values.count, dialect: dialect)
    }
}

/// Why a row cannot be generated into a statement.
public enum DMLGeneratorError: Error, Hashable, CustomStringConvertible {
    case noRowIdentity(TableRef)
    case missingIdentityValue(column: String)
    case noColumnsToWrite

    public var description: String {
        switch self {
        case let .noRowIdentity(table):
            "\(table.name) has no primary key or unique NOT NULL index, so its rows cannot be identified"
        case let .missingIdentityValue(column):
            "No original value for identity column \(column)"
        case .noColumnsToWrite:
            "Nothing to write"
        }
    }
}

/// Builds the `INSERT`, `UPDATE` and `DELETE` statements that a grid commit executes.
///
/// Every `UPDATE` and `DELETE` identifies its row by the identity columns' **original**
/// values and is required to affect exactly one row; the commit flow rolls the whole
/// transaction back otherwise (SPEC §12.3).
public struct DMLGenerator: Sendable {
    public let dialect: SQLDialect
    public let table: TableRef
    /// Primary-key columns, or a unique NOT NULL index, in key order.
    public let identityColumns: [String]

    public init(dialect: SQLDialect, table: TableRef, identityColumns: [String]) {
        self.dialect = dialect
        self.table = table
        self.identityColumns = identityColumns
    }

    var qualifiedTable: String { Identifier.qualified(table, dialect: dialect) }

    /// `UPDATE t SET changed… WHERE identity…`, listing only the columns that changed.
    ///
    /// - Parameters:
    ///   - changes: new values, keyed by column name.
    ///   - originalIdentity: the identity columns' values **as loaded**, so a row that
    ///     changed underneath us fails the affected-row check instead of overwriting.
    public func update(
        changes: [String: DBValue],
        originalIdentity: [String: DBValue]
    ) throws -> GeneratedStatement {
        guard !identityColumns.isEmpty else { throw DMLGeneratorError.noRowIdentity(table) }
        guard !changes.isEmpty else { throw DMLGeneratorError.noColumnsToWrite }

        var parameters = ParameterList(dialect: dialect)
        let assignments = changes.keys.sorted().map { column in
            // Force-unwrap-free: the key came from `changes` itself.
            let value = changes[column] ?? .null
            return "\(Identifier.quote(column, dialect: dialect)) = \(parameters.bind(value))"
        }
        let whereClause = try identityPredicate(originalIdentity, parameters: &parameters)
        let sql = "UPDATE \(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause)"
        return GeneratedStatement(
            kind: .update, sql: sql, parameters: parameters.values,
            table: table, expectsSingleRow: true
        )
    }

    /// `DELETE FROM t WHERE identity…`.
    public func delete(originalIdentity: [String: DBValue]) throws -> GeneratedStatement {
        guard !identityColumns.isEmpty else { throw DMLGeneratorError.noRowIdentity(table) }
        var parameters = ParameterList(dialect: dialect)
        let whereClause = try identityPredicate(originalIdentity, parameters: &parameters)
        let sql = "DELETE FROM \(qualifiedTable) WHERE \(whereClause)"
        return GeneratedStatement(
            kind: .delete, sql: sql, parameters: parameters.values,
            table: table, expectsSingleRow: true
        )
    }

    /// `INSERT INTO t (cols…) VALUES (…)`, listing only the columns the user filled so
    /// every other column takes its server-side default.
    ///
    /// PostgreSQL appends `RETURNING *` so the new row can be shown without a second
    /// round trip; MySQL reads `lastInsertID` from the OK packet instead.
    public func insert(values: [String: DBValue], returnRow: Bool = true) throws -> GeneratedStatement {
        guard !values.isEmpty else {
            // An all-defaults row is still a legitimate insert.
            let sql = dialect == .postgresql
                ? "INSERT INTO \(qualifiedTable) DEFAULT VALUES" + (returnRow ? " RETURNING *" : "")
                : "INSERT INTO \(qualifiedTable) () VALUES ()"
            return GeneratedStatement(
                kind: .insert, sql: sql, parameters: [],
                table: table, expectsSingleRow: true
            )
        }
        var parameters = ParameterList(dialect: dialect)
        let columns = values.keys.sorted()
        let columnList = columns.map { Identifier.quote($0, dialect: dialect) }.joined(separator: ", ")
        let placeholders = columns.map { parameters.bind(values[$0] ?? .null) }.joined(separator: ", ")
        var sql = "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES (\(placeholders))"
        if returnRow, dialect == .postgresql { sql += " RETURNING *" }
        return GeneratedStatement(
            kind: .insert, sql: sql, parameters: parameters.values,
            table: table, expectsSingleRow: true
        )
    }

    /// `SELECT * FROM t WHERE identity…`, used to refetch a row after an insert.
    public func selectByIdentity(_ identity: [String: DBValue]) throws -> GeneratedStatement {
        var parameters = ParameterList(dialect: dialect)
        let whereClause = try identityPredicate(identity, parameters: &parameters)
        return GeneratedStatement(
            kind: .update,
            sql: "SELECT * FROM \(qualifiedTable) WHERE \(whereClause)",
            parameters: parameters.values,
            table: table,
            expectsSingleRow: false
        )
    }

    private func identityPredicate(
        _ identity: [String: DBValue],
        parameters: inout ParameterList
    ) throws -> String {
        try identityColumns.map { column in
            guard let value = identity[column] else {
                throw DMLGeneratorError.missingIdentityValue(column: column)
            }
            let quoted = Identifier.quote(column, dialect: dialect)
            // An identity column should never be NULL, but if one is, `= NULL` would
            // silently match nothing; `IS NULL` at least behaves as the user expects.
            if value.isNull { return "\(quoted) IS NULL" }
            return "\(quoted) = \(parameters.bind(value))"
        }.joined(separator: " AND ")
    }
}
