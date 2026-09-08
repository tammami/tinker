import Foundation
import Logging

/// A database driver: how to open one physical connection to one kind of server.
public protocol SQLDriver: Sendable {
    static var dialect: SQLDialect { get }
    static var displayName: String { get }
    static var defaultPort: Int { get }

    /// Opens one physical connection. `config` is already resolved, so `host` and `port`
    /// point at the real endpoint — the local end of the forward when tunnelled.
    static func connect(_ config: ResolvedConnectionConfig, logger: Logger) async throws -> any SQLConnection
}

/// What the wire between the client and the server looks like, as the server reports it
/// once the connection is up: whether it is encrypted, and with what.
public struct TransportInfo: Sendable, Hashable {
    public var isEncrypted: Bool
    /// `TLSv1.3` and the like; nil when unknown or unencrypted.
    public var protocolVersion: String?
    /// The negotiated cipher suite; nil when unknown or unencrypted.
    public var cipher: String?

    public init(isEncrypted: Bool, protocolVersion: String? = nil, cipher: String? = nil) {
        self.isEncrypted = isEncrypted
        self.protocolVersion = protocolVersion
        self.cipher = cipher
    }

    /// The transport of a connection that never asked: treated as unencrypted.
    public static let plaintext = TransportInfo(isEncrypted: false)

    /// One line for a tooltip: "TLSv1.3, TLS_AES_256_GCM_SHA384" or "Not encrypted".
    public var summary: String {
        guard isEncrypted else { return "Not encrypted" }
        let detail = [protocolVersion, cipher].compactMap { $0 }.joined(separator: ", ")
        return detail.isEmpty ? "Encrypted" : detail
    }
}

/// One physical connection to a server.
///
/// Conformances are actors or otherwise internally synchronised: ``cancelCurrent()``
/// is called from a different task than the one running the query.
public protocol SQLConnection: AnyObject, Sendable {
    var serverVersion: ServerVersion { get async }
    /// The server's identity for this connection — PostgreSQL backend pid, MySQL thread id.
    /// Used to cancel work and shown in the status bar.
    var backendID: String { get }
    /// Whether the wire is encrypted, as the server reported it after the handshake.
    var transport: TransportInfo { get }

    /// Runs one statement and streams its result.
    ///
    /// Drivers never split `sql`; use `DBSQL.StatementSplitter` first. `parameters` are
    /// bound server-side, which is the injection and type-safety boundary for generated DML.
    ///
    /// There are two ways to stop a running statement, and they surface differently:
    /// - ``cancelCurrent()`` asks the server to stop; the stream then throws
    ///   ``DBError/cancelled``. This is what the app's Cancel command uses.
    /// - Cancelling the consuming task also cancels the statement on the server, but
    ///   `AsyncThrowingStream` ends a cancelled iteration without throwing, so the
    ///   consumer learns why from its own `Task.isCancelled`.
    func execute(_ sql: String, parameters: [DBValue]) -> AsyncThrowingStream<QueryEvent, any Error>

    /// Asks the server to stop whatever this connection is running. Safe to call from
    /// another task, and a no-op when the connection is idle.
    func cancelCurrent() async

    func beginTransaction() async throws
    func commit() async throws
    func rollback() async throws
    var isInTransaction: Bool { get async }

    func ping() async throws
    func close() async

    /// Puts session-level state back the way a fresh connection has it — the current
    /// database or search path, the role, variables a statement changed — so a pooled
    /// connection handed to the next tab carries nothing of the last one's `SET`/`USE`.
    /// Drivers may skip the round trip when no such statement ran.
    func resetSessionState() async throws

    var introspector: any SchemaIntrospector { get }

    /// Bulk-loads rows in the server's own text format — PostgreSQL's `COPY … FROM STDIN`.
    ///
    /// `body` is handed a writer and pushes the rows through it; the connection stays in
    /// copy mode until `body` returns or throws. Drivers whose server has no such path
    /// throw ``DBError/protocolError(_:)`` before `body` runs, so a caller can fall back
    /// to `INSERT` statements.
    func copyIn(
        into table: TableRef, columns: [String], body: @Sendable (any BulkLoadWriter) async throws -> Void
    ) async throws
}

/// Where the rows of a bulk load go. Each `write` is one or more whole lines in the
/// server's text format; the driver sends them on without holding them.
public protocol BulkLoadWriter: Sendable {
    func write(_ data: Data) async throws
}

extension SQLConnection {
    /// A driver that cannot tell reports plaintext, which is the honest default.
    public var transport: TransportInfo { .plaintext }

    /// Nothing to reset for a driver that keeps no session state.
    public func resetSessionState() async throws {}

    /// Runs a statement with no parameters and collects every row.
    /// For result sets known to be small — introspection, one-row probes, DDL.
    public func executeCollecting(_ sql: String, parameters: [DBValue] = []) async throws -> QueryResult {
        var columns: [ColumnMeta] = []
        var rows: [[DBValue]] = []
        var completion: QueryCompletion?
        for try await event in execute(sql, parameters: parameters) {
            switch event {
            case let .columns(value): columns = value
            case let .rows(batch): rows.append(contentsOf: batch.rows)
            case let .complete(value): completion = value
            }
        }
        guard let completion else { throw DBError.protocolError("statement finished without a completion event") }
        return QueryResult(columns: columns, rows: rows, completion: completion)
    }

    /// Runs `body` inside a transaction, committing on success and rolling back on any error.
    public func withTransaction<T>(_ body: () async throws -> T) async throws -> T {
        try await beginTransaction()
        do {
            let result = try await body()
            try await commit()
            return result
        } catch {
            // Roll back on the way out; the original error is what the caller needs to see.
            try? await rollback()
            throw error
        }
    }
}

/// A fully collected result set.
public struct QueryResult: Sendable, Hashable {
    public let columns: [ColumnMeta]
    public let rows: [[DBValue]]
    public let completion: QueryCompletion

    public init(columns: [ColumnMeta], rows: [[DBValue]], completion: QueryCompletion) {
        self.columns = columns
        self.rows = rows
        self.completion = completion
    }

    /// The value at `row`, in the column named `name`, or nil when there is no such column.
    public func value(_ row: Int, _ name: String) -> DBValue? {
        guard let index = columns.firstIndex(where: { $0.name == name }), row < rows.count else { return nil }
        return rows[row][index]
    }

    /// Text of the first column of the first row, the shape most probe queries have.
    public var firstText: String? {
        rows.first?.first?.text
    }
}
