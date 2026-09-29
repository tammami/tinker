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
    /// The connection a run is using, so ``stop()`` can reach the statement on it.
    private var running: (any SQLConnection)?
    private var stopRequested = false

    public init(session: ConnectionSession, dialect: SQLDialect) {
        self.session = session
        self.dialect = dialect
    }

    /// True when the engine can undo a failed run. MySQL cannot; PostgreSQL and SQLite can.
    public nonisolated var isTransactional: Bool { dialect != .mysql }

    /// The server's id for the connection a run is using — PostgreSQL backend pid, MySQL
    /// thread id — once the run has one. What ``DDLProgressProbe`` watches.
    public var runningBackendID: String? { running?.backendID }

    /// Asks the server to stop the statement that is running, and skips the ones after it.
    ///
    /// The statement fails with the server's own message (“canceling statement due to
    /// user request”, “Query execution was interrupted”), and the run reports it like any
    /// other failure: rolled back on PostgreSQL, what had already committed on MySQL.
    /// Closing the sheet alone would leave the ALTER running on the server.
    public func stop() async {
        stopRequested = true
        await running?.cancelCurrent()
    }

    public func run(_ statements: [GeneratedDDL]) async throws -> DDLExecutionResult {
        guard !statements.isEmpty else { return DDLExecutionResult(applied: []) }
        stopRequested = false

        // Every statement has to travel on the same connection, or a transaction would not
        // contain them and MySQL's session state would not follow them.
        let transactional = isTransactional
        return try await session.withLease { connection in
            running = connection
            defer { running = nil }
            if transactional { try await connection.beginTransaction() }

            var applied: [GeneratedDDL] = []
            for statement in statements {
                do {
                    if stopRequested { throw DBError.cancelled }
                    _ = try await connection.executeCollecting(statement.sql, parameters: [])
                    applied.append(statement)
                } catch {
                    let message = (error as? DBError)?.errorDescription ?? String(describing: error)
                    if transactional {
                        // A cancelled statement interrupts the connection, and a plain
                        // rollback after it can be refused and swallowed; this one is
                        // checked and bounded. Either way the server has already aborted
                        // the transaction.
                        await connection.rollbackForCleanup()
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
