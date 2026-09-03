import DBCore
import DBSQL
import Foundation

/// Fetches grid pages through a connection session.
///
/// One physical connection is leased per fetch and returned immediately, so a slow page
/// never blocks another tab (SPEC §4).
public struct SessionGridLoader: GridDataLoader {
    let session: ConnectionSession
    let table: TableRef
    let dialect: SQLDialect

    public init(session: ConnectionSession, table: TableRef, dialect: SQLDialect) {
        self.session = session
        self.table = table
        self.dialect = dialect
    }

    public func loadPage(_ request: PageRequest) async throws -> LoadedPage {
        let planner = PagePlanner(dialect: dialect, table: table)
        let filter = FilterCompiler.compile(request.filter, dialect: dialect)
        let query = planner.pageQuery(
            filter: filter,
            sort: request.sort,
            strategy: request.strategy,
            page: request.page,
            keysetAnchor: request.keysetAnchor
        )
        let (lease, connection) = try await session.lease()
        defer { Task { await session.release(lease) } }
        let result = try await connection.executeCollecting(query.sql, parameters: query.parameters)
        return LoadedPage(columns: result.columns, rows: result.rows)
    }

    public func exactCount(filter rules: [FilterRule]) async throws -> Int64 {
        let planner = PagePlanner(dialect: dialect, table: table)
        let compiled = FilterCompiler.compile(rules, dialect: dialect)
        let query = planner.countQuery(filter: compiled)
        let (lease, connection) = try await session.lease()
        defer { Task { await session.release(lease) } }
        let result = try await connection.executeCollecting(query.sql, parameters: query.parameters)
        guard let text = result.firstText, let count = Int64(text) else { return 0 }
        return count
    }
}

/// A loader for a result set that is already in memory, used by query tabs whose rows
/// arrived by streaming rather than by paging.
public struct StreamedGridLoader: GridDataLoader {
    public init() {}

    public func loadPage(_ request: PageRequest) async throws -> LoadedPage {
        LoadedPage(columns: [], rows: [])
    }

    public func exactCount(filter: [FilterRule]) async throws -> Int64 { 0 }
}

/// Runs a grid commit on one leased connection, inside one transaction.
public actor SessionStatementRunner: GridStatementRunner {
    private let session: ConnectionSession
    private var lease: ConnectionSession.Lease?
    private var connection: (any SQLConnection)?

    public init(session: ConnectionSession) {
        self.session = session
    }

    /// Leases the connection the whole commit will run on. The same connection must serve
    /// every statement, or the transaction would not contain them.
    private func acquire() async throws -> any SQLConnection {
        if let connection { return connection }
        let (newLease, newConnection) = try await session.lease()
        lease = newLease
        connection = newConnection
        return newConnection
    }

    private func releaseIfNeeded() async {
        guard let lease else { return }
        await session.release(lease)
        self.lease = nil
        connection = nil
    }

    public func beginTransaction() async throws {
        try await acquire().beginTransaction()
    }

    public func commitTransaction() async throws {
        guard let connection else { return }
        try await connection.commit()
        await releaseIfNeeded()
    }

    public func rollbackTransaction() async throws {
        guard let connection else { return }
        try await connection.rollback()
        await releaseIfNeeded()
    }

    public func run(_ statement: GeneratedStatement) async throws -> StatementOutcome {
        let connection = try await acquire()
        let result = try await connection.executeCollecting(
            statement.sql, parameters: statement.parameters
        )
        return StatementOutcome(
            affectedRows: result.completion.affectedRows,
            returnedRows: result.rows,
            returnedColumns: result.columns,
            lastInsertID: result.completion.lastInsertID
        )
    }
}
