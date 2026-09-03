import DBCore
import Foundation
import Logging

/// A driver that answers from a script instead of a server.
///
/// It lets `ConnectionSession` be tested without any I/O: pool limits, leasing, state
/// transitions, the introspection cache and the read-only guard are all exercised here.
public enum FakeDriver: SQLDriver {
    public static var dialect: SQLDialect { .postgresql }
    public static var displayName: String { "Fake" }
    public static var defaultPort: Int { 5432 }

    /// Controls what the next connections do. Shared by every fake connection.
    public static let control = FakeDriverControl()

    public static func connect(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> any SQLConnection {
        try await control.noteConnect(config)
        return FakeConnection(config: config, control: control)
    }
}

/// The knobs a test turns to steer ``FakeDriver``.
public actor FakeDriverControl {
    public private(set) var connectCount = 0
    public private(set) var lastConfig: ResolvedConnectionConfig?
    public private(set) var closedCount = 0
    /// Endpoints every `connect` saw, so a test can prove a tunnel was used.
    public private(set) var endpoints: [String] = []

    private var failNextConnects = 0
    private var connectError: DBError = .connectionFailed(underlying: "fake failure", hint: nil)
    private var pingFails = false

    public init() {}

    public func reset() {
        connectCount = 0
        lastConfig = nil
        closedCount = 0
        endpoints = []
        failNextConnects = 0
        pingFails = false
    }

    /// Makes the next `count` connection attempts fail with `error`.
    public func failNext(_ count: Int, with error: DBError = .connectionFailed(underlying: "fake failure", hint: nil)) {
        failNextConnects = count
        connectError = error
    }

    /// Makes every pooled connection report itself as dead.
    public func setPingFails(_ fails: Bool) {
        pingFails = fails
    }

    public var shouldPingFail: Bool { pingFails }

    func noteConnect(_ config: ResolvedConnectionConfig) throws {
        if failNextConnects > 0 {
            failNextConnects -= 1
            throw connectError
        }
        connectCount += 1
        lastConfig = config
        endpoints.append("\(config.host):\(config.port)")
    }

    func noteClose() {
        closedCount += 1
    }
}

/// A connection that answers a fixed row for every statement.
public actor FakeConnection: SQLConnection {
    public nonisolated let backendID: String
    public nonisolated let serverVersion = ServerVersion(
        major: 16, minor: 0, patch: 0, flavor: .postgresql, rawString: "Fake PostgreSQL 16.0"
    )
    public nonisolated let introspector: any SchemaIntrospector

    nonisolated let config: ResolvedConnectionConfig
    nonisolated let control: FakeDriverControl

    private var transactionOpen = false
    /// Statements this connection was asked to run, in order.
    public private(set) var executed: [String] = []

    init(config: ResolvedConnectionConfig, control: FakeDriverControl) {
        self.config = config
        self.control = control
        backendID = String(Int.random(in: 1_000 ... 9_999))
        introspector = FakeIntrospector()
    }

    public nonisolated func execute(
        _ sql: String,
        parameters: [DBValue]
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.note(sql)
                continuation.yield(
                    .columns([
                        ColumnMeta(id: 0, name: "value", nativeTypeName: "int4", kind: .int)
                    ]))
                continuation.yield(.rows(RowBatch(rows: [[.int(1)]], startIndex: 0)))
                continuation.yield(
                    .complete(
                        QueryCompletion(
                            affectedRows: 1, serverTag: "SELECT 1", durationTotal: .milliseconds(1)
                        )))
                continuation.finish()
            }
        }
    }

    private func note(_ sql: String) {
        executed.append(sql)
    }

    public func cancelCurrent() async {}

    public func beginTransaction() async throws { transactionOpen = true }
    public func commit() async throws { transactionOpen = false }
    public func rollback() async throws { transactionOpen = false }
    public var isInTransaction: Bool { transactionOpen }

    public func ping() async throws {
        if await control.shouldPingFail { throw DBError.notConnected }
    }

    public func close() async {
        await control.noteClose()
    }
}

/// An introspector that returns a small fixed schema and counts its calls, so cache
/// behaviour is observable.
public final class FakeIntrospector: SchemaIntrospector, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    public init() {}

    public func callCount(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls[name] ?? 0
    }

    private func note(_ name: String) {
        lock.lock()
        calls[name, default: 0] += 1
        lock.unlock()
    }

    public func databases() async throws -> [DatabaseInfo] {
        note("databases")
        return [DatabaseInfo(name: "fake", isCurrent: true)]
    }

    public func schemas(in database: String) async throws -> [SchemaInfo] {
        note("schemas")
        return [SchemaInfo(ref: SchemaRef(database: database, schema: "public"))]
    }

    public func tables(in schema: SchemaRef) async throws -> [TableInfo] {
        note("tables")
        return [TableInfo(ref: TableRef(schema: schema, name: "users"), kind: .table)]
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        note("columns")
        return [
            ColumnInfo(
                ordinal: 1, name: "id", nativeType: "integer", kind: .int, isNullable: false, isPrimaryKey: true),
            ColumnInfo(ordinal: 2, name: "name", nativeType: "text", kind: .string, isNullable: true),
        ]
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        note("indexes")
        return [IndexInfo(name: "users_pkey", columns: ["id"], isUnique: true, isPrimary: true, isNullableFree: true)]
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        note("foreignKeys")
        return []
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        note("primaryKey")
        return ["id"]
    }

    public func routines(in schema: SchemaRef) async throws -> [RoutineInfo] {
        note("routines")
        return []
    }

    public func tableDDL(_ table: TableRef) async throws -> String {
        note("tableDDL")
        return "CREATE TABLE \(table.name) (id integer PRIMARY KEY)"
    }

    public func approximateRowCount(_ table: TableRef) async throws -> Int64? {
        note("approximateRowCount")
        return 42
    }
}

/// A tunnel provider that hands out a fixed local port without opening anything.
public actor FakeTunnelProvider: TunnelProvider {
    public private(set) var openCount = 0
    public private(set) var lastTarget: String?
    private let port: Int
    private var failure: DBError?

    public init(port: Int = 55_432) {
        self.port = port
    }

    public func setFailure(_ error: DBError?) {
        failure = error
    }

    public func openTunnel(
        _ config: SSHConfig,
        to remoteHost: String,
        port remotePort: Int,
        secrets: any SecretStore,
        logger: Logger
    ) async throws -> any Tunnel {
        if let failure { throw failure }
        openCount += 1
        lastTarget = "\(remoteHost):\(remotePort)"
        return FakeTunnel(localPort: port)
    }
}

public actor FakeTunnel: Tunnel {
    public nonisolated let localPort: Int
    private var open = true

    init(localPort: Int) {
        self.localPort = localPort
    }

    public var isOpen: Bool { open }

    public func close() async {
        open = false
    }
}

// MARK: - Table designer reads

extension FakeIntrospector {
    public func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo] {
        note("checkConstraints")
        return [CheckConstraintInfo(name: "positive_id", expression: "id > 0")]
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        note("triggers")
        return []
    }

    public func partitioning(of table: TableRef) async throws -> PartitioningInfo? {
        note("partitioning")
        return nil
    }

    public func collations(in database: String) async throws -> [CollationInfo] {
        note("collations")
        return [CollationInfo(name: "C", isDefault: true)]
    }
}
