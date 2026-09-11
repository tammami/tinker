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

/// How a session reaches its server: the wire's encryption and whether an SSH tunnel
/// carries it.
public struct TransportSummary: Sendable, Hashable {
    public let transport: TransportInfo
    public let isTunnelled: Bool

    public init(transport: TransportInfo, isTunnelled: Bool) {
        self.transport = transport
        self.isTunnelled = isTunnelled
    }

    /// True when every hop is protected: TLS on the wire, or an SSH tunnel around it.
    /// A database file read in-process has no hop to protect.
    public var isProtected: Bool { transport.isEncrypted || isTunnelled || transport.isLocalFile }

    /// One line for the status bar tooltip.
    public var summary: String {
        var parts: [String] = []
        if isTunnelled { parts.append("SSH tunnel") }
        parts.append(transport.summary)
        return parts.joined(separator: " · ")
    }
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
    /// How long ``lease()`` waits for a connection when every one is in use before it
    /// gives up. Waiting forever showed as a tab stuck on "Running…" with nothing to cancel.
    public static let leaseWaitTimeout: Duration = .seconds(15)
    /// How often idle pooled connections are pinged (SPEC §4: "idle keepalive 60s"), so a
    /// socket that died while the laptop slept is found and dropped before a tab needs it.
    public static let keepaliveInterval: Duration = .seconds(60)
    /// How long a ping may take before the connection is given up as half-open. Without
    /// a deadline every lease queued behind one hung ping for as long as TCP took to
    /// notice, which is minutes.
    public static let pingTimeout: Duration = .seconds(5)

    public nonisolated let config: ConnectionConfig
    private let registry: DriverRegistry
    private let secrets: any SecretStore
    private let tunnelProvider: (any TunnelProvider)?
    private let logger: Logger
    private let clock: any Clock<Duration>
    private let leaseWaitTimeout: Duration
    private let keepaliveInterval: Duration
    private let pingTimeout: Duration
    /// Pings idle connections every `keepaliveInterval`; started with the first pooled
    /// connection and cancelled by `disconnect()`.
    private var keepaliveTask: Task<Void, Never>?

    private var tunnel: (any Tunnel)?
    private var pool: [PooledConnection] = []
    private var leaseCounter = 0
    private var cache = IntrospectionCache()
    private var stateValue: ConnectionState = .disconnected
    private var stateSubscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    /// Set when the user unlocks a read-only connection for this session (`⌘⇧L`).
    private var readOnlyOverridden = false
    /// True while ``disconnect()`` is closing the pool; a lease that arrives then is
    /// refused rather than opening a connection the close would leak.
    private var isClosing = false
    /// Set when a connection dropped while a transaction was open. The session then
    /// refuses to reconnect on its own — a new session would silently discard the
    /// uncommitted work — until the user reconnects explicitly (SPEC §9.6).
    private var lostTransaction: String?

    /// Who has a pooled connection. Every state change happens between suspension
    /// points, so no two callers can find the same connection free.
    private enum Occupancy: Equatable {
        case idle
        case leased(UUID)
        /// Being rolled back and reset after a release; not free until that finishes.
        case resetting
        /// Being pinged before it is handed out; not free until the ping answers.
        case checking
    }

    /// One physical connection and who is using it.
    private struct PooledConnection {
        let id: Int
        let connection: any SQLConnection
        var occupancy: Occupancy
        var lastUsed: ContinuousClock.Instant
        /// The read-only state last told to the server on this connection; nil when it
        /// has to be told again (never yet, or the lock changed while it was leased).
        var readOnlyApplied: Bool?

        var isIdle: Bool { occupancy == .idle }
        var leasedTo: UUID? { if case let .leased(id) = occupancy { id } else { nil } }
    }

    private func poolIndex(of id: Int) -> Int? { pool.firstIndex { $0.id == id } }

    /// The session whose SSH tunnel this one rides on, for a session opened on another
    /// database of the same server. Nil for the connection's own session.
    private let tunnelSource: ConnectionSession?

    public init(
        config: ConnectionConfig,
        registry: DriverRegistry,
        secrets: any SecretStore,
        tunnelProvider: (any TunnelProvider)? = nil,
        tunnelSource: ConnectionSession? = nil,
        logger: Logger = Logger(label: "tinker.session"),
        clock: any Clock<Duration> = ContinuousClock(),
        leaseWaitTimeout: Duration = ConnectionSession.leaseWaitTimeout,
        keepaliveInterval: Duration = ConnectionSession.keepaliveInterval,
        pingTimeout: Duration = ConnectionSession.pingTimeout
    ) {
        self.config = config
        self.registry = registry
        self.secrets = secrets
        self.tunnelProvider = tunnelProvider
        self.tunnelSource = tunnelSource
        self.logger = logger
        self.clock = clock
        self.leaseWaitTimeout = leaseWaitTimeout
        self.keepaliveInterval = keepaliveInterval
        self.pingTimeout = pingTimeout
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
    ///
    /// The server is told as well: every idle connection gets the new setting now, and
    /// a leased one gets it the next time it is handed out.
    public func setReadOnlyOverride(_ overridden: Bool) async {
        readOnlyOverridden = overridden
        // The pool can change across every await below, so work from ids, never indices.
        for id in pool.map(\.id) {
            guard let index = poolIndex(of: id) else { continue }
            guard pool[index].isIdle else {
                pool[index].readOnlyApplied = nil
                continue
            }
            let connection = pool[index].connection
            pool[index].occupancy = .checking
            await applyReadOnlyGuard(to: connection)
            guard let current = poolIndex(of: id) else { continue }
            pool[current].occupancy = .idle
            pool[current].readOnlyApplied = isReadOnly
        }
    }

    /// Tells the server whether this connection may write, so the guard holds for every
    /// statement whatever it looks like — `EXPLAIN ANALYZE DELETE`, `SELECT … INTO`, a
    /// function with side effects — and not only for what the client recognises as a
    /// write. A connection that was never read-only is left alone.
    ///
    /// Held connections (a query tab keeps one) are not in the pool's hands, so their
    /// owner calls this before each run.
    public func applyReadOnlyGuard(to connection: any SQLConnection) async {
        guard config.readOnly else { return }
        let sql =
            switch config.dialect {
            case .postgresql: "SET default_transaction_read_only = \(isReadOnly ? "on" : "off")"
            case .mysql: "SET SESSION TRANSACTION READ \(isReadOnly ? "ONLY" : "WRITE")"
            case .sqlite: "PRAGMA query_only = \(isReadOnly ? 1 : 0)"
            }
        do {
            _ = try await connection.executeCollecting(sql)
        } catch {
            logger.warning(
                "read-only guard not applied",
                metadata: ["error": "\((error as? DBError)?.errorDescription ?? "\(error)")"])
        }
    }

    // MARK: - Connecting

    /// Opens the tunnel, if configured, and one physical connection.
    /// Calling it when already connected is a no-op.
    @discardableResult
    public func connect() async throws -> ServerVersion {
        if let lostTransaction {
            throw DBError.connectionFailed(underlying: lostTransaction, hint: "reconnect from the sidebar to continue")
        }
        if let existing = pool.first {
            setState(.connected)
            return await existing.connection.serverVersion
        }
        let connection = try await makeConnection()
        if isClosing {
            await connection.close()
            throw DBError.notConnected
        }
        pool.append(
            PooledConnection(
                id: nextConnectionID(), connection: connection, occupancy: .idle, lastUsed: .now
            ))
        startKeepaliveIfNeeded()
        setState(.connected)
        return await connection.serverVersion
    }

    /// The user's explicit answer to a lost transaction: give up the uncommitted work and
    /// connect again. Only this clears the refusal that ``noteConnectionDropped`` set,
    /// so that nothing the app does on its own (a transfer, a dump, the query builder)
    /// can make that decision for the user.
    @discardableResult
    public func reconnect() async throws -> ServerVersion {
        lostTransaction = nil
        return try await connect()
    }

    /// Runs the whole connect path and reports each stage, for the editor's Test Connection.
    ///
    /// The published state is what it was before the test when the test returns: a
    /// connected session stays connected in the sidebar, not stuck on "connecting".
    public func testConnection(
        report: @escaping @Sendable (TunnelStage, String) -> Void
    ) async -> Result<ServerVersion, DBError> {
        let previous = stateValue
        defer { setState(previous) }
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

    /// The SSH tunnel for this session's configuration, opened if it is not up. Sessions
    /// on the server's other databases borrow it, so a server reached over SSH costs one
    /// SSH connection however many of its databases are open.
    public func openTunnelIfNeeded() async throws -> (any Tunnel)? {
        guard let ssh = config.ssh else { return nil }
        guard let provider = tunnelProvider else {
            throw DBError.tunnelFailed(stage: .ssh, underlying: "This build has no SSH support registered")
        }
        var needsNewTunnel = true
        if let existing = tunnel { needsNewTunnel = !(await existing.isOpen) }
        if needsNewTunnel {
            tunnel = try await provider.openTunnel(
                ssh, to: config.host, port: config.port, secrets: secrets, logger: logger
            )
        }
        return tunnel
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
            setState(.connecting(stage: .ssh))
            report?(.ssh, "Opening SSH connection to \(ssh.user)@\(ssh.host):\(ssh.port)…")
            if let tunnelSource {
                // Another database of the same server: one SSH connection serves them all.
                tunnel = try await tunnelSource.openTunnelIfNeeded()
            } else {
                _ = try await openTunnelIfNeeded()
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

    /// Opens one physical connection, with one retry when the failure is the network's
    /// rather than the server's answer (SPEC §9.6: "reconnect on next use with one
    /// retry"). A refused password or a missing database is not retried: the second
    /// attempt would only say the same thing later.
    private func makeConnection() async throws -> any SQLConnection {
        do {
            let resolved = try await resolveConfig()
            do {
                return try await registry.connect(resolved, logger: logger)
            } catch let error as DBError where error.indicatesLostConnection {
                logger.debug("connect failed; retrying once", metadata: ["error": "\(error)"])
                try Task.checkCancellation()
                // The tunnel may be what fell; resolving again reopens it if so.
                let again = try await resolveConfig()
                return try await registry.connect(again, logger: logger)
            }
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
        var waitedSince: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            guard !isClosing else { throw DBError.notConnected }
            if let lostTransaction {
                throw DBError.connectionFailed(
                    underlying: lostTransaction, hint: "reconnect from the sidebar to continue")
            }
            try await reapIdleConnections()

            if let index = pool.firstIndex(where: \.isIdle) {
                // A pooled connection may have died while it sat idle; prove it is alive
                // before handing it out. It is marked first so that no other caller finds
                // it free during the ping, and everything after the await goes back
                // through its id: the pool can have changed shape meanwhile.
                let candidate = pool[index]
                pool[index].occupancy = .checking
                do {
                    try await pingWithDeadline(candidate.connection)
                } catch {
                    if let current = poolIndex(of: candidate.id) { pool.remove(at: current) }
                    await candidate.connection.close()
                    continue
                }
                guard let current = poolIndex(of: candidate.id) else {
                    // Only a disconnect (or a drop) removes a connection that is being
                    // checked: the session was torn down under this caller, and the
                    // close was left to whoever held the statement in flight.
                    await candidate.connection.close()
                    throw DBError.notConnected
                }
                let newLease = Lease(id: UUID(), connectionID: candidate.id)
                pool[current].occupancy = .leased(newLease.id)
                pool[current].lastUsed = .now
                if config.readOnly, pool[current].readOnlyApplied != isReadOnly {
                    await applyReadOnlyGuard(to: candidate.connection)
                    if let again = poolIndex(of: candidate.id) { pool[again].readOnlyApplied = isReadOnly }
                }
                setState(.connected)
                return (newLease, candidate.connection)
            }

            guard pool.count < Self.maximumPoolSize else {
                // Every connection is in use. The pool frees up as soon as any tab finishes
                // its statement or closes, so a short wait is normal; a long one is a tab
                // that will never let go, and the caller is told so instead of hanging.
                let since = waitedSince ?? .now
                waitedSince = since
                if since.duration(to: .now) >= leaseWaitTimeout {
                    throw DBError.connectionFailed(
                        underlying:
                            "All \(Self.maximumPoolSize) connections of “\(config.name)” are in use",
                        hint: "close a tab or wait for a running statement to finish")
                }
                try await clock.sleep(for: .milliseconds(50))
                continue
            }

            let connection = try await makeConnection()
            if isClosing {
                await connection.close()
                throw DBError.notConnected
            }
            let id = nextConnectionID()
            let newLease = Lease(id: UUID(), connectionID: id)
            pool.append(
                PooledConnection(
                    id: id, connection: connection, occupancy: .leased(newLease.id), lastUsed: .now
                ))
            startKeepaliveIfNeeded()
            if config.readOnly {
                await applyReadOnlyGuard(to: connection)
                if let current = poolIndex(of: id) { pool[current].readOnlyApplied = isReadOnly }
            }
            setState(.connected)
            return (newLease, connection)
        }
    }

    /// Returns a connection to the pool.
    ///
    /// Whatever the connection was doing is rolled back — unconditionally, because a
    /// transaction the driver did not see open (`SET autocommit = 0` typed on MySQL, a
    /// `BEGIN` inside a `DO` block) would otherwise be committed by the reset that
    /// follows — and session state (`USE`, `search_path`, `SET ROLE`, variables) is put
    /// back so the next tab starts where a fresh connection would. The connection is not
    /// free until all of that has finished: a lease that arrives meanwhile takes another.
    public func release(_ lease: Lease) async {
        guard let index = poolIndex(of: lease.connectionID),
            pool[index].leasedTo == lease.id
        else { return }
        pool[index].occupancy = .resetting
        let connection = pool[index].connection
        // ROLLBACK outside a transaction is a warning on every engine, never an error.
        try? await connection.rollback()
        do {
            try await connection.resetSessionState()
        } catch {
            // A connection that cannot be reset is not handed out again.
            logger.debug("session reset failed; dropping the connection", metadata: ["error": "\(error)"])
            if let current = poolIndex(of: lease.connectionID) { pool.remove(at: current) }
            await connection.close()
            return
        }
        guard let current = poolIndex(of: lease.connectionID) else {
            // Disconnected while resetting; the disconnect left the close to this
            // release so that the reset's statement was not cut off mid-flight.
            await connection.close()
            return
        }
        pool[current].occupancy = .idle
        pool[current].lastUsed = .now
        // The reset also clears the server-side read-only guard; the next lease applies
        // it again rather than trusting what this one remembers.
        pool[current].readOnlyApplied = nil
    }

    /// Leases a connection for the duration of `body` and returns it before returning,
    /// whichever way `body` ends.
    ///
    /// The alternative — `defer { Task { await release(lease) } }` — hands the connection
    /// back on a task nobody waits for, so the caller's next lease races it and opens a
    /// connection the pool did not need. Runs on the caller's actor, so `body` may touch
    /// the caller's own state.
    public nonisolated(nonsending) func withLease<T>(
        _ body: (any SQLConnection) async throws -> T
    ) async throws -> T {
        let (lease, connection) = try await lease()
        let value: T
        do {
            value = try await body(connection)
        } catch {
            await release(lease)
            throw error
        }
        await release(lease)
        return value
    }

    /// The transport of this session's connections, as the server reported it: whether
    /// the wire is encrypted and whether it runs through an SSH tunnel. Nil before the
    /// first connection is up.
    public var transportSummary: TransportSummary? {
        guard let first = pool.first else { return nil }
        return TransportSummary(transport: first.connection.transport, isTunnelled: tunnel != nil)
    }

    /// Closes connections that have sat unused past the idle timeout.
    private func reapIdleConnections() async throws {
        let deadline = ContinuousClock.Instant.now - Self.idleTimeout
        // Keep at least one connection so the session stays warm.
        var expired = pool.filter { $0.isIdle && $0.lastUsed < deadline }
        // When every connection has expired, the most recently used one stays.
        if expired.count == pool.count, let newest = expired.max(by: { $0.lastUsed < $1.lastUsed }) {
            expired.removeAll { $0.id == newest.id }
        }
        // Remove before the first await, so nothing else can lease a connection that is
        // about to be closed.
        pool.removeAll { candidate in expired.contains { $0.id == candidate.id } }
        for removed in expired { await removed.connection.close() }
    }

    public var pooledConnectionCount: Int { pool.count }
    public var leasedConnectionCount: Int { pool.filter { $0.leasedTo != nil }.count }

    // MARK: - Keepalive

    /// Starts the keepalive loop with the first pooled connection. Structured to the
    /// session: `disconnect()` cancels it, and a cancelled loop ends at its next sleep.
    private func startKeepaliveIfNeeded() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self, clock, keepaliveInterval] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: keepaliveInterval) } catch { return }
                guard let self else { return }
                await self.pingIdleConnections()
            }
        }
    }

    /// Pings every idle connection with a deadline and drops the ones that do not answer,
    /// then closes the ones idle past the timeout. A connection that died while the
    /// machine slept is found here, not by the next tab that needed it.
    private func pingIdleConnections() async {
        for id in pool.map(\.id) {
            guard let index = poolIndex(of: id), pool[index].isIdle else { continue }
            let candidate = pool[index]
            pool[index].occupancy = .checking
            do {
                try await pingWithDeadline(candidate.connection)
                if let current = poolIndex(of: id) { pool[current].occupancy = .idle }
            } catch {
                logger.debug("keepalive ping failed; dropping the connection", metadata: ["error": "\(error)"])
                if let current = poolIndex(of: id) { pool.remove(at: current) }
                await candidate.connection.close()
            }
        }
        try? await reapIdleConnections()
    }

    /// `ping()` bounded by `pingTimeout`. A hung ping is abandoned, not awaited: a driver
    /// whose ping does not observe cancellation (an event-loop future) would otherwise
    /// hold every lease behind it until TCP gave up.
    private func pingWithDeadline(_ connection: any SQLConnection) async throws {
        let timeout = pingTimeout
        let clock = clock
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OnceFlag()
            let ping = Task {
                do {
                    try await connection.ping()
                    if once.trip() { continuation.resume() }
                } catch {
                    if once.trip() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await clock.sleep(for: timeout)
                guard once.trip() else { return }
                ping.cancel()
                continuation.resume(throwing: DBError.timeout(after: timeout))
            }
        }
    }

    /// Trips once, from any thread.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        func trip() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if tripped { return false }
            tripped = true
            return true
        }
    }

    // MARK: - Failure handling

    /// Records that a statement failed because the connection went away.
    ///
    /// The session refuses to reconnect behind the user's back while a transaction was
    /// open, because silently starting a new session would discard uncommitted work
    /// without saying so (SPEC §9).
    public func noteConnectionDropped(lease: Lease, hadOpenTransaction: Bool) async {
        if let index = poolIndex(of: lease.connectionID) {
            let removed = pool.remove(at: index)
            await removed.connection.close()
        }
        let reason =
            hadOpenTransaction
            ? "The connection dropped while a transaction was open. Reconnect to continue; uncommitted work is lost."
            : "The connection dropped. It will be reopened on next use."
        if hadOpenTransaction { lostTransaction = reason }
        setState(.degraded(reason: reason))
    }

    /// True while the session waits for the user to reconnect after a transaction was
    /// lost; leases are refused until ``connect()`` is called.
    public var isWaitingForReconnect: Bool { lostTransaction != nil }

    /// Closes the tunnel and every connection.
    public func disconnect() async {
        // Take the pool first, so a lease that arrives while the closes are in flight
        // finds nothing to reuse and is refused rather than handed a closing connection.
        isClosing = true
        defer { isClosing = false }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        let closing = pool
        pool.removeAll()
        // A connection in the middle of a ping or a reset has a statement in flight;
        // closing it now would tear the channel out from under that statement (mysql-nio
        // asserts on it). The lease or release that owns the statement finds the
        // connection gone from the pool when it resumes and closes it then.
        for pooled in closing where pooled.occupancy != .resetting && pooled.occupancy != .checking {
            await pooled.connection.close()
        }
        cache.invalidateAll()
        // A borrowed tunnel belongs to the connection's own session and outlives this one.
        if tunnelSource == nil { await tunnel?.close() }
        tunnel = nil
        setState(.disconnected)
    }

    /// Drops everything cached about one table: its columns, key, indexes, constraints,
    /// triggers and partitioning, and the schema listing that carries its row count.
    public func invalidateIntrospection(for table: TableRef) {
        cache.invalidate(table: table)
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
        // Released before returning, not in a detached task: the caller's next lease
        // must find this connection free rather than racing the release for a new one.
        let value: Value
        do {
            value = try await load(connection.introspector)
        } catch {
            await release(lease)
            throw error
        }
        await release(lease)
        cache.store(value, for: key)
        return value
    }

    /// What the cache holds for a key, without reading anything on a miss.
    public func cachedIntrospection<Value: Sendable>(_ key: IntrospectionCache.Key) -> Value? {
        cache.value(for: key)
    }

    /// The same cache, read through a connection the caller already holds.
    ///
    /// A run of reads for one table — columns, key, indexes, foreign keys, checks,
    /// triggers — leases once and goes through here, so a cold cache costs one connection
    /// rather than one per read; on a fresh session each miss would otherwise open its own.
    public func introspection<Value: Sendable>(
        _ key: IntrospectionCache.Key,
        on connection: any SQLConnection,
        load: @Sendable (any SchemaIntrospector) async throws -> Value
    ) async throws -> Value {
        if let cached: Value = cache.value(for: key) { return cached }
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
        case tableInfo(TableRef)
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
                let .viewDefinition(table), let .tableInfo(table):
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
