import Foundation
import Logging

/// What a session is doing, as shown by the sidebar dot and the status bar.
public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting(stage: TunnelStage)
    case connected
    /// The connection dropped or failed while in use. The session does not reconnect on
    /// its own while a transaction was open; the user decides (SPEC §9).
    case degraded(reason: String)

    public var isUsable: Bool { if case .connected = self { true } else { false } }
}

/// One live connection to one configured server, shared by every window and tab that uses
/// that configuration.
///
/// The session owns the SSH tunnel, the pool of physical connections, and the
/// introspection cache. It is the only place that reads secrets.
public actor ConnectionSession {
    /// Physical connections a single session may hold (SPEC §4).
    public static let maximumPoolSize = 8
    /// How long an unused connection is kept before it is closed.
    public static let idleTimeout: Duration = .seconds(300)

    public nonisolated let config: ConnectionConfig
    private let registry: DriverRegistry
    private let secrets: any SecretStore
    private let tunnelProvider: (any TunnelProvider)?
    private let logger: Logger
    private let clock: any Clock<Duration>

    private var tunnel: (any Tunnel)?
    private var pool: [PooledConnection] = []
    private var leaseCounter = 0
    private var cache = IntrospectionCache()
    private var stateValue: ConnectionState = .disconnected
    private var stateSubscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    /// Set when the user unlocks a read-only connection for this session (`⌘⇧L`).
    private var readOnlyOverridden = false

    /// One physical connection and who is using it.
    private struct PooledConnection {
        let id: Int
        let connection: any SQLConnection
        var leasedTo: UUID?
        var lastUsed: ContinuousClock.Instant
    }

    public init(
        config: ConnectionConfig,
        registry: DriverRegistry,
        secrets: any SecretStore,
        tunnelProvider: (any TunnelProvider)? = nil,
        logger: Logger = Logger(label: "dbstudio.session"),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.config = config
        self.registry = registry
        self.secrets = secrets
        self.tunnelProvider = tunnelProvider
        self.logger = logger
        self.clock = clock
    }

    // MARK: - State

    public var state: ConnectionState { stateValue }

    /// A stream of state changes, starting with the current state.
    ///
    /// The stream ends when the subscriber stops iterating; the session drops its
    /// continuation then, so an abandoned window leaves nothing behind.
    public func states() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            stateSubscribers[id] = continuation
            continuation.yield(stateValue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        stateSubscribers.removeValue(forKey: id)
    }

    private func setState(_ newState: ConnectionState) {
        guard newState != stateValue else { return }
        stateValue = newState
        for continuation in stateSubscribers.values { continuation.yield(newState) }
    }

    // MARK: - Read-only guard

    /// True when the session refuses writes: the config says read-only and the user has
    /// not unlocked it for this session.
    public var isReadOnly: Bool { config.readOnly && !readOnlyOverridden }

    /// Unlocks or re-locks writes for the lifetime of this session only. Never persisted.
    public func setReadOnlyOverride(_ overridden: Bool) {
        readOnlyOverridden = overridden
    }

    // MARK: - Connecting

    /// Opens the tunnel, if configured, and one physical connection.
    /// Calling it when already connected is a no-op.
    @discardableResult
    public func connect() async throws -> ServerVersion {
        if let existing = pool.first {
            setState(.connected)
            return await existing.connection.serverVersion
        }
        let connection = try await makeConnection()
        pool.append(
            PooledConnection(
                id: nextConnectionID(), connection: connection, leasedTo: nil, lastUsed: .now
            ))
        setState(.connected)
        return await connection.serverVersion
    }

    /// Runs the whole connect path and reports each stage, for the editor's Test Connection.
    public func testConnection(
        report: @escaping @Sendable (TunnelStage, String) -> Void
    ) async -> Result<ServerVersion, DBError> {
        do {
            let resolved = try await resolveConfig(report: report)
            report(.startup, "Connecting to \(resolved.host):\(resolved.port)…")
            let connection = try await registry.connect(resolved, logger: logger)
            let version = await connection.serverVersion
            report(.startup, "Connected to \(version.rawString)")
            await connection.close()
            return .success(version)
        } catch let error as DBError {
            return .failure(error)
        } catch {
            return .failure(.connectionFailed(underlying: String(reflecting: error), hint: nil))
        }
    }

    /// Resolves secrets and, when configured, opens the tunnel, returning a config that
    /// points at whichever endpoint the driver should dial.
    private func resolveConfig(
        report: (@Sendable (TunnelStage, String) -> Void)? = nil
    ) async throws -> ResolvedConnectionConfig {
        let password: String?
        if let reference = config.passwordRef {
            password = try await secrets.secret(for: reference)
        } else {
            password = nil
        }

        var host = config.host
        var port = config.port

        if let ssh = config.ssh {
            guard let provider = tunnelProvider else {
                throw DBError.tunnelFailed(
                    stage: .ssh, underlying: "This build has no SSH support registered"
                )
            }
            setState(.connecting(stage: .ssh))
            report?(.ssh, "Opening SSH connection to \(ssh.user)@\(ssh.host):\(ssh.port)…")
            var needsNewTunnel = true
            if let existing = tunnel { needsNewTunnel = !(await existing.isOpen) }
            if needsNewTunnel {
                tunnel = try await provider.openTunnel(
                    ssh, to: config.host, port: config.port, secrets: secrets, logger: logger
                )
            }
            guard let tunnel else {
                throw DBError.tunnelFailed(stage: .portForward, underlying: "The tunnel closed immediately")
            }
            report?(.portForward, "Forwarding 127.0.0.1:\(tunnel.localPort) → \(config.host):\(config.port)")
            host = "127.0.0.1"
            port = tunnel.localPort
        }

        setState(.connecting(stage: config.tls.mode.requiresTLS ? .tls : .auth))
        return ResolvedConnectionConfig(
            configID: config.id,
            dialect: config.dialect,
            host: host,
            port: port,
            // Certificates name the real server, not the local end of the forward.
            tlsServerName: config.tls.serverNameOverride ?? config.host,
            user: config.user,
            password: password,
            database: config.database,
            tls: config.tls,
            options: config.options,
            statementTimeout: config.statementTimeout
        )
    }

    private func makeConnection() async throws -> any SQLConnection {
        do {
            let resolved = try await resolveConfig()
            return try await registry.connect(resolved, logger: logger)
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(reflecting: error)
            setState(.degraded(reason: message))
            throw error
        }
    }

    private func nextConnectionID() -> Int {
        leaseCounter += 1
        return leaseCounter
    }

    // MARK: - Pool

    /// A borrowed physical connection, returned with ``release(_:)``.
    public struct Lease: Sendable, Hashable {
        public let id: UUID
        fileprivate let connectionID: Int
    }

    /// Borrows a connection for a tab. Each tab gets its own, so a long query in one tab
    /// does not block another. Waits when the pool is full.
    public func lease() async throws -> (Lease, any SQLConnection) {
        // A loop rather than recursion: a busy pool can be retried many times and the
        // stack must not grow with each retry.
        while true {
            try Task.checkCancellation()
            try await reapIdleConnections()

            if let index = pool.firstIndex(where: { $0.leasedTo == nil }) {
                // A pooled connection may have died while it sat idle; prove it is alive
                // before handing it out.
                do {
                    try await pool[index].connection.ping()
                } catch {
                    guard let current = pool.firstIndex(where: { $0.id == pool[index].id }) else { continue }
                    let dead = pool.remove(at: current)
                    await dead.connection.close()
                    continue
                }
                guard let index = pool.firstIndex(where: { $0.leasedTo == nil }) else { continue }
                let newLease = Lease(id: UUID(), connectionID: pool[index].id)
                pool[index].leasedTo = newLease.id
                pool[index].lastUsed = .now
                setState(.connected)
                return (newLease, pool[index].connection)
            }

            guard pool.count < Self.maximumPoolSize else {
                // Every connection is in use. Waiting beats failing, and the pool frees up
                // as soon as any tab finishes its statement.
                try await clock.sleep(for: .milliseconds(50))
                continue
            }

            let connection = try await makeConnection()
            let id = nextConnectionID()
            let newLease = Lease(id: UUID(), connectionID: id)
            pool.append(
                PooledConnection(
                    id: id, connection: connection, leasedTo: newLease.id, lastUsed: .now
                ))
            setState(.connected)
            return (newLease, connection)
        }
    }

    /// Returns a connection to the pool. A connection left inside a transaction is rolled
    /// back first, so the next tab never inherits someone else's uncommitted work.
    public func release(_ lease: Lease) async {
        guard let index = pool.firstIndex(where: { $0.id == lease.connectionID }) else { return }
        pool[index].leasedTo = nil
        pool[index].lastUsed = .now
        let connection = pool[index].connection
        if await connection.isInTransaction {
            try? await connection.rollback()
        }
    }

    /// Closes connections that have sat unused past the idle timeout.
    private func reapIdleConnections() async throws {
        let deadline = ContinuousClock.Instant.now - Self.idleTimeout
        // Keep at least one connection so the session stays warm.
        let expired = pool.enumerated()
            .filter { $0.element.leasedTo == nil && $0.element.lastUsed < deadline }
            .map(\.offset)
        guard pool.count - expired.count >= 1 else { return }
        for index in expired.reversed() {
            let removed = pool.remove(at: index)
            await removed.connection.close()
        }
    }

    public var pooledConnectionCount: Int { pool.count }
    public var leasedConnectionCount: Int { pool.filter { $0.leasedTo != nil }.count }

    // MARK: - Failure handling

    /// Records that a statement failed because the connection went away.
    ///
    /// The session refuses to reconnect behind the user's back while a transaction was
    /// open, because silently starting a new session would discard uncommitted work
    /// without saying so (SPEC §9).
    public func noteConnectionDropped(lease: Lease, hadOpenTransaction: Bool) async {
        if let index = pool.firstIndex(where: { $0.id == lease.connectionID }) {
            let removed = pool.remove(at: index)
            await removed.connection.close()
        }
        setState(
            .degraded(
                reason: hadOpenTransaction
                    ? "The connection dropped while a transaction was open. Reconnect to continue; uncommitted work is lost."
                    : "The connection dropped. It will be reopened on next use."))
    }

    /// Closes the tunnel and every connection.
    public func disconnect() async {
        for pooled in pool { await pooled.connection.close() }
        pool.removeAll()
        cache.invalidateAll()
        await tunnel?.close()
        tunnel = nil
        setState(.disconnected)
    }

    // MARK: - Introspection cache

    /// Schema reads, cached until something invalidates them explicitly.
    /// Nothing here refreshes on a timer (SPEC §8).
    public func introspection<Value: Sendable>(
        _ key: IntrospectionCache.Key,
        load: @Sendable (any SchemaIntrospector) async throws -> Value
    ) async throws -> Value {
        if let cached: Value = cache.value(for: key) { return cached }
        let (lease, connection) = try await lease()
        defer { Task { await release(lease) } }
        let value = try await load(connection.introspector)
        cache.store(value, for: key)
        return value
    }

    /// Drops cached schema information. Called by the user's Refresh and after the app
    /// itself runs DDL.
    public func invalidateIntrospection(_ key: IntrospectionCache.Key? = nil) {
        if let key { cache.invalidate(key) } else { cache.invalidateAll() }
    }
}

/// A typed key-value cache for schema reads.
public struct IntrospectionCache: Sendable {
    /// What a cached entry describes.
    public enum Key: Sendable, Hashable {
        case databases
        case schemas(database: String)
        case tables(SchemaRef)
        case columns(TableRef)
        case indexes(TableRef)
        case foreignKeys(TableRef)
        case primaryKey(TableRef)
        case routines(SchemaRef)
        case ddl(TableRef)
        case rowCount(TableRef)
        case checkConstraints(TableRef)
        case triggers(TableRef)
        case partitioning(TableRef)
        case collations(database: String)
        case viewDefinition(TableRef)
        case routineDefinition(SchemaRef, name: String, signature: String)
        case users
        case variables

        /// The table an entry belongs to, so one table's DDL change clears just that table.
        public var table: TableRef? {
            switch self {
            case let .columns(table), let .indexes(table), let .foreignKeys(table),
                let .primaryKey(table), let .ddl(table), let .rowCount(table),
                let .checkConstraints(table), let .triggers(table), let .partitioning(table),
                let .viewDefinition(table):
                table
            default:
                nil
            }
        }
    }

    private var storage: [Key: any Sendable] = [:]

    public init() {}

    public func value<Value: Sendable>(for key: Key) -> Value? {
        // The presence check has to come first. Casting a missing entry straight to
        // `Value` succeeds whenever `Value` is itself optional — `nil as? [String]?`
        // yields `.some(nil)` — so a miss would report itself as a hit holding nothing,
        // and a loader returning an optional (`rowIdentity`, `approximateRowCount`) would
        // never run at all.
        guard let boxed = storage[key] else { return nil }
        return boxed as? Value
    }

    public mutating func store<Value: Sendable>(_ value: Value, for key: Key) {
        storage[key] = value
    }

    public mutating func invalidate(_ key: Key) {
        storage.removeValue(forKey: key)
    }

    /// Drops every entry describing `table`, which is what a DDL change on it requires.
    public mutating func invalidate(table: TableRef) {
        for key in storage.keys where key.table == table { storage.removeValue(forKey: key) }
    }

    public mutating func invalidateAll() {
        storage.removeAll()
    }

    public var count: Int { storage.count }
}
