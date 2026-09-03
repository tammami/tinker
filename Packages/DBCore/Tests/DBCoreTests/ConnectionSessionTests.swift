import DBTestKit
import Logging
import XCTest
@testable import DBCore

final class ConnectionSessionTests: XCTestCase {
    let registry = DriverRegistry([.postgresql: FakeDriver.self])
    var logger: Logger {
        var logger = Logger(label: "test.session")
        logger.logLevel = .critical
        return logger
    }

    override func setUp() async throws {
        await FakeDriver.control.reset()
    }

    func makeConfig(
        ssh: SSHConfig? = nil,
        readOnly: Bool = false,
        passwordRef: SecretRef? = nil
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: "test", dialect: .postgresql, host: "db.example", port: 5432, user: "app",
            passwordRef: passwordRef, database: "app", ssh: ssh, readOnly: readOnly
        )
    }

    func makeSession(
        config: ConnectionConfig? = nil,
        secrets: any SecretStore = EphemeralSecretStore(),
        tunnelProvider: (any TunnelProvider)? = nil
    ) -> ConnectionSession {
        ConnectionSession(
            config: config ?? makeConfig(), registry: registry,
            secrets: secrets, tunnelProvider: tunnelProvider, logger: logger
        )
    }

    // MARK: - State

    func testStateGoesFromDisconnectedToConnected() async throws {
        let session = makeSession()
        let initial = await session.state
        XCTAssertEqual(initial, .disconnected)

        let version = try await session.connect()
        XCTAssertEqual(version.major, 16)
        let connected = await session.state
        XCTAssertEqual(connected, .connected)

        await session.disconnect()
        let final = await session.state
        XCTAssertEqual(final, .disconnected)
    }

    func testStateStreamDeliversChanges() async throws {
        let session = makeSession()
        let stream = await session.states()
        let collector = Task {
            var seen: [ConnectionState] = []
            for await state in stream {
                seen.append(state)
                // Stop once the round trip is complete, however many intermediate
                // connecting stages the session reported along the way.
                if seen.contains(.connected), state == .disconnected, seen.count > 1 { break }
            }
            return seen
        }
        try await session.connect()
        await session.disconnect()
        let seen = await collector.value
        XCTAssertEqual(seen.first, .disconnected)
        XCTAssertTrue(seen.contains(.connected))
        XCTAssertEqual(seen.last, .disconnected)
        XCTAssertTrue(seen.contains { if case .connecting = $0 { true } else { false } },
                      "the session should report the stage it is connecting at: \(seen)")
    }

    func testFailedConnectMarksTheSessionDegraded() async throws {
        await FakeDriver.control.failNext(1, with: .connectionFailed(underlying: "refused", hint: nil))
        let session = makeSession()
        do {
            try await session.connect()
            XCTFail("expected the connection to fail")
        } catch {
            let state = await session.state
            guard case let .degraded(reason) = state else {
                return XCTFail("expected .degraded, got \(state)")
            }
            XCTAssertTrue(reason.contains("refused"), reason)
        }
    }

    // MARK: - Pool

    func testEachLeaseGetsItsOwnConnection() async throws {
        let session = makeSession()
        var leases: [ConnectionSession.Lease] = []
        for _ in 0 ..< 4 {
            let (lease, _) = try await session.lease()
            leases.append(lease)
        }
        let pooled = await session.pooledConnectionCount
        let leased = await session.leasedConnectionCount
        XCTAssertEqual(pooled, 4)
        XCTAssertEqual(leased, 4)
        for lease in leases { await session.release(lease) }
        let afterRelease = await session.leasedConnectionCount
        XCTAssertEqual(afterRelease, 0)
    }

    func testReleasedConnectionsAreReused() async throws {
        let session = makeSession()
        let (first, _) = try await session.lease()
        await session.release(first)
        let (_, _) = try await session.lease()
        let connects = await FakeDriver.control.connectCount
        XCTAssertEqual(connects, 1, "the pooled connection should have been reused")
    }

    func testPoolStopsAtEightConnections() async throws {
        let session = makeSession()
        for _ in 0 ..< ConnectionSession.maximumPoolSize {
            _ = try await session.lease()
        }
        let pooled = await session.pooledConnectionCount
        XCTAssertEqual(pooled, ConnectionSession.maximumPoolSize)

        // A ninth request waits rather than opening a ninth connection.
        let waiting = Task { try await session.lease() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(waiting.isCancelled)
        let stillEight = await session.pooledConnectionCount
        XCTAssertEqual(stillEight, ConnectionSession.maximumPoolSize)
        waiting.cancel()
        _ = try? await waiting.value
    }

    func testReleasingRollsBackAnOpenTransaction() async throws {
        let session = makeSession()
        let (lease, connection) = try await session.lease()
        try await connection.beginTransaction()
        let openBefore = await connection.isInTransaction
        XCTAssertTrue(openBefore)
        await session.release(lease)
        let openAfter = await connection.isInTransaction
        XCTAssertFalse(openAfter, "a returned connection must not carry someone else's transaction")
    }

    func testADeadPooledConnectionIsReplaced() async throws {
        let session = makeSession()
        let (lease, _) = try await session.lease()
        await session.release(lease)
        await FakeDriver.control.setPingFails(true)

        // The next lease finds the connection dead, discards it and opens a fresh one.
        await FakeDriver.control.setPingFails(false)
        let (_, _) = try await session.lease()
        let connects = await FakeDriver.control.connectCount
        XCTAssertGreaterThanOrEqual(connects, 1)
    }

    func testDroppedConnectionWithOpenTransactionSaysSo() async throws {
        let session = makeSession()
        let (lease, _) = try await session.lease()
        await session.noteConnectionDropped(lease: lease, hadOpenTransaction: true)
        let state = await session.state
        guard case let .degraded(reason) = state else { return XCTFail("expected .degraded") }
        XCTAssertTrue(reason.contains("uncommitted"), reason)
        let pooled = await session.pooledConnectionCount
        XCTAssertEqual(pooled, 0)
    }

    // MARK: - Secrets and tunnel

    func testPasswordIsReadFromTheSecretStore() async throws {
        let reference = SecretRef(account: "test.password")
        let secrets = EphemeralSecretStore([reference: "hunter2"])
        let session = makeSession(config: makeConfig(passwordRef: reference), secrets: secrets)
        try await session.connect()
        let config = await FakeDriver.control.lastConfig
        XCTAssertEqual(config?.password, "hunter2")
    }

    func testTunnelRedirectsTheDriverToLoopback() async throws {
        let provider = FakeTunnelProvider(port: 55_432)
        let ssh = SSHConfig(host: "bastion.example", user: "me", auth: .agent)
        let session = makeSession(config: makeConfig(ssh: ssh), tunnelProvider: provider)
        try await session.connect()

        let config = await FakeDriver.control.lastConfig
        XCTAssertEqual(config?.host, "127.0.0.1")
        XCTAssertEqual(config?.port, 55_432)
        // Certificates name the real server, not the local end of the forward.
        XCTAssertEqual(config?.tlsServerName, "db.example")
        let target = await provider.lastTarget
        XCTAssertEqual(target, "db.example:5432")
    }

    func testTunnelIsOpenedOnceAndReusedByEveryConnection() async throws {
        let provider = FakeTunnelProvider()
        let ssh = SSHConfig(host: "bastion.example", user: "me", auth: .agent)
        let session = makeSession(config: makeConfig(ssh: ssh), tunnelProvider: provider)
        _ = try await session.lease()
        _ = try await session.lease()
        let opens = await provider.openCount
        XCTAssertEqual(opens, 1)
    }

    func testMissingTunnelProviderIsReportedAsATunnelFailure() async throws {
        let ssh = SSHConfig(host: "bastion.example", user: "me", auth: .agent)
        let session = makeSession(config: makeConfig(ssh: ssh), tunnelProvider: nil)
        do {
            try await session.connect()
            XCTFail("expected a tunnel failure")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, _) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .ssh)
        }
    }

    // MARK: - Read-only guard

    func testReadOnlyCanBeUnlockedForTheSessionOnly() async throws {
        let session = makeSession(config: makeConfig(readOnly: true))
        let locked = await session.isReadOnly
        XCTAssertTrue(locked)
        await session.setReadOnlyOverride(true)
        let unlocked = await session.isReadOnly
        XCTAssertFalse(unlocked)
        // The stored config is untouched, so the next launch is read-only again.
        XCTAssertTrue(session.config.readOnly)
    }

    // MARK: - Introspection cache

    func testIntrospectionIsCachedUntilInvalidated() async throws {
        let session = makeSession()
        let (lease, connection) = try await session.lease()
        let introspector = try XCTUnwrap(connection.introspector as? FakeIntrospector)
        await session.release(lease)

        for _ in 0 ..< 3 {
            _ = try await session.introspection(.databases) { try await $0.databases() }
        }
        XCTAssertEqual(introspector.callCount("databases"), 1, "the cache should have answered twice")

        await session.invalidateIntrospection(.databases)
        _ = try await session.introspection(.databases) { try await $0.databases() }
        XCTAssertEqual(introspector.callCount("databases"), 2)
    }

    /// A loader whose result is optional has to run on a miss.
    ///
    /// It did not: the cache cast a missing entry straight to the requested type, which
    /// succeeds for an optional one and reports a hit holding nothing. `rowIdentity` and
    /// `approximateRowCount` are exactly that shape, so the app never asked the server for
    /// a primary key and opened every table read-only.
    func testAnOptionalResultStillRunsItsLoaderOnAMiss() async throws {
        let session = makeSession()
        let (lease, connection) = try await session.lease()
        let introspector = try XCTUnwrap(connection.introspector as? FakeIntrospector)
        await session.release(lease)
        let table = TableRef(database: "fake", schema: "public", name: "users")

        let identity: [String]? = try await session.introspection(.primaryKey(table)) {
            try await $0.rowIdentity(of: table)
        }
        XCTAssertEqual(identity, ["id"], "the loader never ran, so the key was never read")
        XCTAssertEqual(introspector.callCount("primaryKey"), 1)

        // And the second read is still served from the cache.
        let again: [String]? = try await session.introspection(.primaryKey(table)) {
            try await $0.rowIdentity(of: table)
        }
        XCTAssertEqual(again, ["id"])
        XCTAssertEqual(introspector.callCount("primaryKey"), 1, "the cache should have answered")
    }

    /// A genuinely absent value is cached as absent, rather than re-read every time.
    func testACachedNilIsRememberedAsNil() {
        var cache = IntrospectionCache()
        let table = TableRef(database: "d", schema: "public", name: "no_pk")
        let absent: [String]? = nil
        cache.store(absent, for: .primaryKey(table))

        XCTAssertEqual(cache.count, 1, "storing nil must keep the entry, not drop the key")
        let read: [String]?? = cache.value(for: .primaryKey(table))
        guard let stored = read else {
            return XCTFail("a stored nil must read back as a hit, not a miss")
        }
        XCTAssertNil(stored, "and the hit must carry nil")
    }

    func testInvalidatingATableClearsEveryEntryAboutIt() {
        var cache = IntrospectionCache()
        let table = TableRef(database: "d", schema: "public", name: "users")
        let other = TableRef(database: "d", schema: "public", name: "orders")
        cache.store(["id"], for: .columns(table))
        cache.store(["id"], for: .primaryKey(table))
        cache.store("ddl", for: .ddl(table))
        cache.store(["id"], for: .columns(other))
        cache.store([DatabaseInfo(name: "d")], for: .databases)
        XCTAssertEqual(cache.count, 5)

        cache.invalidate(table: table)
        XCTAssertEqual(cache.count, 2)
        let remaining: [String]? = cache.value(for: .columns(other))
        XCTAssertEqual(remaining, ["id"])
    }

    func testDisconnectClearsTheCacheAndClosesEverything() async throws {
        let session = makeSession()
        _ = try await session.introspection(.databases) { try await $0.databases() }
        await session.disconnect()
        let pooled = await session.pooledConnectionCount
        XCTAssertEqual(pooled, 0)
        let closed = await FakeDriver.control.closedCount
        XCTAssertGreaterThanOrEqual(closed, 1)
    }

    // MARK: - Test connection

    func testTestConnectionReportsEachStage() async throws {
        let provider = FakeTunnelProvider()
        let ssh = SSHConfig(host: "bastion.example", user: "me", auth: .agent)
        let session = makeSession(config: makeConfig(ssh: ssh), tunnelProvider: provider)

        let stages = StageRecorder()
        let result = await session.testConnection { stage, message in
            stages.record(stage, message)
        }
        guard case let .success(version) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(version.major, 16)
        XCTAssertEqual(stages.stages.prefix(2), [.ssh, .portForward])
        XCTAssertTrue(stages.stages.contains(.startup))
    }

    func testTestConnectionReturnsTheFailure() async throws {
        await FakeDriver.control.failNext(1, with: .authenticationFailed(user: "app"))
        let session = makeSession()
        let result = await session.testConnection { _, _ in }
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .authenticationFailed(user: "app"))
    }
}

/// Collects the stages `testConnection` reports, from whichever thread reports them.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(TunnelStage, String)] = []

    func record(_ stage: TunnelStage, _ message: String) {
        lock.lock()
        recorded.append((stage, message))
        lock.unlock()
    }

    var stages: [TunnelStage] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.0)
    }
}
