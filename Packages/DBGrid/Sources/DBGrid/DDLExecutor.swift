import DBCore
import DBSQL
import Foundation

/// What running a set of structure statements did (SPEC §15b.2).
public struct DDLExecutionResult: Sendable, Hashable {
    /// Statements that reached the server and were not rolled back.
    public let applied: [GeneratedDDL]
    /// The statement that failed, if one did.
    public let failed: GeneratedDDL?
    /// The server's own words, never rewritten (SPEC §6).
    public let errorText: String?
    /// True when the engine undid everything on failure.
    public let didRollBack: Bool

    public var isSuccess: Bool { failed == nil }

    public init(
        applied: [GeneratedDDL],
        failed: GeneratedDDL? = nil,
        errorText: String? = nil,
        didRollBack: Bool = false
    ) {
        self.applied = applied
        self.failed = failed
        self.errorText = errorText
        self.didRollBack = didRollBack
    }
}

/// Runs structure statements on one connection, in order.
///
/// PostgreSQL wraps DDL in a transaction and undoes the lot when one statement fails.
/// MySQL commits each statement implicitly, so a failure part-way leaves everything before
/// it applied. The executor does not paper over that difference: it reports which
/// statements survived so the user is told the truth rather than "the change failed".
public actor DDLExecutor {
    private let session: ConnectionSession
    private let dialect: SQLDialect

    public init(session: ConnectionSession, dialect: SQLDialect) {
        self.session = session
        self.dialect = dialect
    }

    /// True when the engine can undo a failed run. MySQL cannot; PostgreSQL and SQLite can.
    public nonisolated var isTransactional: Bool { dialect != .mysql }

    public func run(_ statements: [GeneratedDDL]) async throws -> DDLExecutionResult {
        guard !statements.isEmpty else { return DDLExecutionResult(applied: []) }

        // Every statement has to travel on the same connection, or a transaction would not
        // contain them and MySQL's session state would not follow them.
        let transactional = isTransactional
        return try await session.withLease { connection in
            if transactional { try await connection.beginTransaction() }

            var applied: [GeneratedDDL] = []
            for statement in statements {
                do {
                    _ = try await connection.executeCollecting(statement.sql, parameters: [])
                    applied.append(statement)
                } catch {
                    let message = (error as? DBError)?.errorDescription ?? String(describing: error)
                    if transactional {
                        // Best effort: if the rollback itself fails the connection is going
                        // back to the pool anyway, and the server has already aborted the
                        // transaction.
                        try? await connection.rollback()
                        return DDLExecutionResult(
                            applied: [], failed: statement, errorText: message, didRollBack: true
                        )
                    }
                    return DDLExecutionResult(
                        applied: applied, failed: statement, errorText: message, didRollBack: false
                    )
                }
            }

            if transactional { try await connection.commit() }
            return DDLExecutionResult(applied: applied)
        }
    }
}
