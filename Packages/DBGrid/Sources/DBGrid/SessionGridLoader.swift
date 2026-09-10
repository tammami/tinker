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
        let result = try await session.withLease { connection in
            try await connection.executeCollecting(query.sql, parameters: query.parameters)
        }
        return LoadedPage(columns: result.columns, rows: result.rows)
    }

    public func exactCount(filter rules: [FilterRule]) async throws -> Int64 {
        let planner = PagePlanner(dialect: dialect, table: table)
        let compiled = FilterCompiler.compile(rules, dialect: dialect)
        let query = planner.countQuery(filter: compiled)
        let result = try await session.withLease { connection in
            try await connection.executeCollecting(query.sql, parameters: query.parameters)
        }
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

/// Pages a query's result on the server, the way a table tab pages a table.
///
/// The statement is wrapped as `SELECT * FROM (…) AS page LIMIT n OFFSET m`, so a
/// `SELECT` over fifty thousand rows costs one page of them, on the wire and in
/// memory, and the pager reads the rest on demand. Only statements that can stand
/// inside a subquery qualify; everything else — `SHOW`, `EXPLAIN` — streams as before.
public struct QueryGridLoader: GridDataLoader {
    public let statement: String
    public let dialect: SQLDialect
    public let pageSize: Int
    /// Hands back the connection a page runs on: the tab's own held one, so a query
    /// inside a transaction pages over what that transaction sees.
    let acquire: @Sendable () async throws -> any SQLConnection

    public init(
        statement: String, dialect: SQLDialect, pageSize: Int = 1_000,
        acquire: @escaping @Sendable () async throws -> any SQLConnection
    ) {
        self.statement = statement
        self.dialect = dialect
        self.pageSize = pageSize
        self.acquire = acquire
    }

    /// True for statements a subquery can hold.
    public static func isPageable(_ sql: String, dialect: SQLDialect) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        switch statement.leadingKeyword {
        case "SELECT", "WITH", "VALUES":
            break
        case "TABLE":
            guard dialect == .postgresql else { return false }
        default:
            return false
        }
        // Locking and cursor clauses cannot sit inside a subquery.
        let upper = sql.uppercased()
        return !upper.contains("FOR UPDATE") && !upper.contains("FOR SHARE") && !upper.contains("INTO OUTFILE")
    }

    static func stripped(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    public static func pageSQL(_ sql: String, page: Int, pageSize: Int) -> String {
        "SELECT * FROM (\(stripped(sql))) AS tinker_page LIMIT \(pageSize) OFFSET \(page * pageSize)"
    }

    public static func countSQL(_ sql: String) -> String {
        "SELECT count(*) FROM (\(stripped(sql))) AS tinker_page"
    }

    public func loadPage(_ request: PageRequest) async throws -> LoadedPage {
        let connection = try await acquire()
        let result = try await connection.executeCollecting(
            Self.pageSQL(statement, page: request.page, pageSize: pageSize))
        return LoadedPage(columns: result.columns, rows: result.rows)
    }

    public func exactCount(filter: [FilterRule]) async throws -> Int64 {
        let connection = try await acquire()
        let result = try await connection.executeCollecting(Self.countSQL(statement))
        guard let value = result.rows.first?.first else { return 0 }
        switch value {
        case let .int(number): return number
        case let .uint(number): return Int64(number)
        default: return Int64(value.text ?? "") ?? 0
        }
    }
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
