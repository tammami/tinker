import DBCore
import DBSQL
import Foundation

/// What running one generated statement produced.
public struct StatementOutcome: Sendable, Hashable {
    public let affectedRows: Int64?
    /// Rows the statement returned, for `INSERT … RETURNING`.
    public let returnedRows: [[DBValue]]
    public let returnedColumns: [ColumnMeta]
    /// MySQL's generated key, where the server reports one.
    public let lastInsertID: Int64?

    public init(
        affectedRows: Int64?,
        returnedRows: [[DBValue]] = [],
        returnedColumns: [ColumnMeta] = [],
        lastInsertID: Int64? = nil
    ) {
        self.affectedRows = affectedRows
        self.returnedRows = returnedRows
        self.returnedColumns = returnedColumns
        self.lastInsertID = lastInsertID
    }
}

/// Runs the statements a grid commit produces, inside one transaction.
///
/// Declared here so the commit rules can be tested without a database; the app implements
/// it over a leased `SQLConnection`.
public protocol GridStatementRunner: Sendable {
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    func run(_ statement: GeneratedStatement) async throws -> StatementOutcome
}

/// Why a commit stopped.
public enum GridCommitError: Error, Hashable, CustomStringConvertible {
    /// The row the statement addressed was not there, or matched more than once.
    case unexpectedAffectedRows(expected: Int64, actual: Int64, statement: String)
    /// The server refused a statement; everything is rolled back.
    case statementFailed(statement: String, underlying: String)
    case readOnly

    public var description: String {
        switch self {
        case let .unexpectedAffectedRows(expected, actual, _):
            "Expected \(expected) row, got \(actual) — data may have changed since load"
        case let .statementFailed(_, underlying):
            underlying
        case .readOnly:
            "This connection is read-only"
        }
    }

    /// The statement that failed, so the preview sheet can highlight it.
    public var statement: String? {
        switch self {
        case let .unexpectedAffectedRows(_, _, statement), let .statementFailed(statement, _): statement
        case .readOnly: nil
        }
    }
}

/// What a successful commit did.
public struct CommitResult: Sendable {
    public let statementCount: Int
    public let totalAffectedRows: Int64
    /// Rows the inserts returned, so the grid can show the real values without a reload.
    public let insertedRows: [[DBValue]]
    public let insertedColumns: [ColumnMeta]

    public init(
        statementCount: Int,
        totalAffectedRows: Int64,
        insertedRows: [[DBValue]] = [],
        insertedColumns: [ColumnMeta] = []
    ) {
        self.statementCount = statementCount
        self.totalAffectedRows = totalAffectedRows
        self.insertedRows = insertedRows
        self.insertedColumns = insertedColumns
    }
}

/// Executes a grid commit under the rules in SPEC §12.3.
///
/// Every statement runs inside one transaction. An `UPDATE` or `DELETE` that does not
/// affect exactly one row means the row changed underneath the user, so the whole
/// transaction rolls back and the edit buffer is left untouched for them to retry.
public struct GridCommitter: Sendable {
    public init() {}

    public func commit(
        _ statements: [GeneratedStatement],
        using runner: any GridStatementRunner
    ) async throws -> CommitResult {
        guard !statements.isEmpty else {
            return CommitResult(statementCount: 0, totalAffectedRows: 0)
        }

        try await runner.beginTransaction()
        var totalAffected: Int64 = 0
        var insertedRows: [[DBValue]] = []
        var insertedColumns: [ColumnMeta] = []

        for statement in statements {
            let outcome: StatementOutcome
            do {
                outcome = try await runner.run(statement)
            } catch {
                try? await runner.rollbackTransaction()
                let message = (error as? DBError)?.errorDescription ?? String(describing: error)
                throw GridCommitError.statementFailed(statement: statement.sql, underlying: message)
            }

            if statement.expectsSingleRow {
                // An INSERT … RETURNING reports its count through the rows it returned.
                let affected = outcome.affectedRows ?? Int64(outcome.returnedRows.count)
                guard affected == 1 else {
                    try? await runner.rollbackTransaction()
                    throw GridCommitError.unexpectedAffectedRows(
                        expected: 1, actual: affected, statement: statement.sql
                    )
                }
                totalAffected += affected
            } else {
                totalAffected += outcome.affectedRows ?? 0
            }

            if statement.kind == .insert, !outcome.returnedRows.isEmpty {
                insertedRows.append(contentsOf: outcome.returnedRows)
                if insertedColumns.isEmpty { insertedColumns = outcome.returnedColumns }
            }
        }

        do {
            try await runner.commitTransaction()
        } catch {
            try? await runner.rollbackTransaction()
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            throw GridCommitError.statementFailed(statement: "COMMIT", underlying: message)
        }

        return CommitResult(
            statementCount: statements.count,
            totalAffectedRows: totalAffected,
            insertedRows: insertedRows,
            insertedColumns: insertedColumns
        )
    }
}
